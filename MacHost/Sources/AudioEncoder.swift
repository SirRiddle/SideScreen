import AudioToolbox
import CoreMedia
import Foundation

/// AAC-LC encoder for the ScreenCaptureKit audio path: audio of apps on the
/// captured display → AAC access units → ADTS-framed bytes for the wire.
///
/// Design notes:
/// - Output sample rate follows the INPUT rate (no SRC — modern macOS delivers
///   48kHz, and the client builds its decoder CSD from the ADTS header).
/// - Channel count clamps to 1–2 (min(2, input)) — AAC-LC covers every source.
/// - An internal PCM accumulator decouples SCK's variable-size audio buffers
///   from AAC's fixed 1024-frame access units. All state is confined to one
///   serial queue.
final class AudioEncoder {
    /// (adtsFramedAAC, uptimeNanos) — the stamp shares the video path's clock so
    /// the client can align A/V (DispatchTime.now().uptimeNanoseconds).
    var onEncodedAccessUnit: ((Data, UInt64) -> Void)?

    private let queue = DispatchQueue(label: "audioEncoder", qos: .userInteractive)
    private var converter: AudioConverterRef?
    private var outSampleRate: Float64 = 48000
    private var outChannels: UInt32 = 2
    private var inBytesPerFrame: UInt32 = 0

    // Per-plane accumulators: SCK delivers NON-interleaved (planar) Float32 —
    // one AudioBuffer per channel — while interleaved sources give one buffer.
    // The AAC converter is fed with the same plane layout the input declares.
    private var planeAccums: [[UInt8]] = []
    private var accumFrames = 0

    private var inputPlanes: [[UInt8]] = []
    private var inputProvided = false

    func encode(sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            self?._encode(sampleBuffer)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if let c = self.converter {
                AudioConverterDispose(c)
                self.converter = nil
            }
            self.planeAccums.removeAll()
            self.accumFrames = 0
        }
    }

    // MARK: - Queue-confined

    private func _encode(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let inASBD = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0, inASBD.mBytesPerFrame > 0 else { return }

        if converter == nil || inBytesPerFrame != inASBD.mBytesPerFrame ||
            outSampleRate != inASBD.mSampleRate ||
            outChannels != min(2, max(1, inASBD.mChannelsPerFrame)) {
            rebuildConverter(input: inASBD)
        }
        guard converter != nil else { return }

        // Two-call sizing: real SCK audio is planar, needing a multi-buffer ABL.
        var sizeNeeded = 0
        var blockBuffer: CMBlockBuffer?
        let preflight = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard preflight == noErr, sizeNeeded > 0 else { return }

        let ablStorage = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 8)
        defer { ablStorage.deallocate() }
        let abl = ablStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockOut: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: abl,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockOut
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard !buffers.isEmpty, let first = buffers.first, first.mData != nil,
              first.mDataByteSize > 0, inBytesPerFrame > 0 else { return }

        let planes = buffers.map { buf -> [UInt8] in
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                             count: Int(buf.mDataByteSize)))
        }
        ingest(planes: planes, framesPerBuffer: Int(first.mDataByteSize) / Int(inBytesPerFrame))
    }

    /// Extraction-independent ingestion (also the unit-test seam): plane-major
    /// PCM, one array per ABL buffer — one per channel for planar sources, one
    /// interleaved array otherwise. Queue-confined like the rest of this class.
    func ingest(planes: [[UInt8]], framesPerBuffer frames: Int) {
        guard frames > 0, !planes.isEmpty else { return }
        if planeAccums.count != planes.count {
            planeAccums = (0..<planes.count).map { _ in [] }
            accumFrames = 0  // conservative: a layout change drops partial residue
        }
        for (i, plane) in planes.enumerated() where !plane.isEmpty {
            planeAccums[i].append(contentsOf: plane)
        }
        accumFrames += frames

        while accumFrames >= 1024 {
            let auPlaneByteCount = 1024 * Int(inBytesPerFrame)
            inputPlanes = planeAccums.map { Array($0[0..<auPlaneByteCount]) }
            for i in planeAccums.indices {
                planeAccums[i] = Array(planeAccums[i].dropFirst(auPlaneByteCount))
            }
            accumFrames -= 1024
            if let encoded = encodeAccessUnit() {
                onEncodedAccessUnit?(encoded, DispatchTime.now().uptimeNanoseconds)
            }
        }
    }

    private func encodeAccessUnit() -> Data? {
        guard let converter, !inputPlanes.isEmpty else { return nil }
        inputProvided = false

        let outCapacity = 4096
        let outStorage = UnsafeMutableRawPointer.allocate(byteCount: outCapacity, alignment: 8)
        defer { outStorage.deallocate() }
        var outBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: outChannels, mDataByteSize: UInt32(outCapacity), mData: outStorage)
        )

        var ioOutputDataPacketSize: UInt32 = 1
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioConverterFillComplexBuffer(
            converter,
            { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                guard let inUserData else { return -1 }
                let encoder = Unmanaged<AudioEncoder>.fromOpaque(inUserData).takeUnretainedValue()
                if encoder.inputProvided {
                    // One AAC AU consumes exactly 1024 frames; a second request
                    // means the input ended — terminate cleanly.
                    ioNumberDataPackets.pointee = 0
                    return noErr
                }
                encoder.inputProvided = true
                let list = UnsafeMutableAudioBufferListPointer(ioData)
                ioData.pointee.mNumberBuffers = UInt32(encoder.inputPlanes.count)
                for (i, plane) in encoder.inputPlanes.enumerated() {
                    plane.withUnsafeBytes { raw in
                        list[i].mData = UnsafeMutableRawPointer(mutating: raw.baseAddress)
                        list[i].mDataByteSize = UInt32(plane.count)
                        list[i].mNumberChannels = encoder.inputPlanes.count > 1 ? 1 : encoder.outChannels
                    }
                }
                if let outDataPacketDescription {
                    outDataPacketDescription.pointee = nil
                }
                ioNumberDataPackets.pointee = UInt32(encoder.inputPlanes.isEmpty ? 0 : encoder.inputPlanes[0].count / max(1, Int(encoder.inBytesPerFrame)))
                return noErr
            },
            ctx,
            &ioOutputDataPacketSize,
            &outBufferList,
            nil
        )
        guard status == noErr, ioOutputDataPacketSize == 1, outBufferList.mBuffers.mDataByteSize > 0 else { return nil }

        let aac = Data(bytes: outStorage, count: Int(outBufferList.mBuffers.mDataByteSize))
        return Self.addADTSHeader(to: aac, sampleRate: outSampleRate, channels: outChannels)
    }
    /// Test hook: build the converter exactly as _encode would for the given
    /// layout. Internal probe seam — not part of the runtime contract.
    func probeConfigure(sampleRate: Double, channels: Int, interleaved: Bool) {
        queue.sync {
            var flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
            let bpf = UInt32(interleaved ? 4 * channels : 4)
            let asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags, mBytesPerPacket: bpf, mFramesPerPacket: 1,
                mBytesPerFrame: bpf, mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 32, mReserved: 0)
            inBytesPerFrame = bpf
            rebuildConverter(input: asbd)
        }
    }

    private func rebuildConverter(input inASBD: AudioStreamBasicDescription) {
        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }

        inBytesPerFrame = inASBD.mBytesPerFrame
        outSampleRate = inASBD.mSampleRate
        outChannels = min(2, max(1, inASBD.mChannelsPerFrame))
        planeAccums.removeAll()
        accumFrames = 0

        var outASBD = AudioStreamBasicDescription(
            mSampleRate: outSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: outChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var mutableIn = inASBD
        var newConverter: AudioConverterRef?
        let status = AudioConverterNew(&mutableIn, &outASBD, &newConverter)
        guard status == noErr, let newConverter else {
            debugLog("AudioConverterNew failed: \(status)")
            return
        }
        var bitrate: UInt32 = 128_000
        AudioConverterSetProperty(newConverter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        converter = newConverter
        debugLog("Audio encoder ready: \(Int(outSampleRate))Hz \(outChannels)ch AAC-LC 128kbps")
    }

    /// 7-byte ADTS header (protection_absent=1) per ETSI TS 126 401, AAC-LC.
    static func addADTSHeader(to aac: Data, sampleRate: Float64, channels: UInt32) -> Data {
        let freqTable: [Float64] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        var srIndex = 3  // 48k fallback
        for (i, f) in freqTable.enumerated() where abs(f - sampleRate) < 1 {
            srIndex = i
            break
        }
        let chanCfg = Int(channels)
        let frameLength = aac.count + 7

        var out = Data(capacity: frameLength)
        out.append(0xFF)
        out.append(0xF1)  // sync(12), MPEG-4, layer 0, protection_absent
        out.append(UInt8((1 << 6) | (srIndex << 2) | ((chanCfg >> 2) & 0x1)))  // profile=AAC LC
        out.append(UInt8(((chanCfg & 0x3) << 6) | ((frameLength >> 11) & 0x3)))
        out.append(UInt8((frameLength >> 3) & 0xFF))
        out.append(UInt8(((frameLength & 0x7) << 5) | 0x1F))
        out.append(0xFC)
        out.append(aac)
        return out
    }
}
