package com.sidescreen.app

import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import java.util.concurrent.atomic.AtomicLong

/**
 * Decodes ADTS-framed AAC access units from the Mac and plays PCM through an
 * AudioTrack. Modelled on VideoDecoder: async MediaCodec callbacks on a
 * dedicated AUDIO-priority HandlerThread, drop-and-resync on decoder errors.
 *
 * The decoder's CSD is derived from the first ADTS header (sample-rate index +
 * channel config), so the Mac can switch rates without any handshake.
 * Frames are raw AAC (ADTS stripped) into the codec.
 */
class AudioPlayer {
    private var codec: MediaCodec? = null
    private var track: AudioTrack? = null
    private var configuredSampleRate = 0
    private var configuredChannels = 0

    private val thread =
        HandlerThread("AudioDecodeThread").apply {
            start()
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            } catch (_: Exception) {
            }
        }
    private val handler = Handler(thread.looper)

    private val frameCounter = AtomicLong(0)

    /** Feed one ADTS-framed AU. Safe to call from any thread. */
    fun feed(
        adts: ByteArray,
        size: Int,
    ) {
        // Copy: the caller's buffer is recycled; codec input needs its own copy window.
        val copy = adts.copyOf(size)
        handler.post { drain(copy, copy.size) }
    }

    fun release() {
        handler.post {
            try {
                codec?.stop()
                codec?.release()
            } catch (_: Exception) {
            }
            codec = null
            try {
                track?.pause()
                track?.flush()
                track?.release()
            } catch (_: Exception) {
            }
            track = null
            configuredSampleRate = 0
            configuredChannels = 0
        }
        thread.quitSafely()
    }

    // MARK: - handler-thread-confined

    private fun drain(
        adts: ByteArray,
        size: Int,
    ) {
        // ADTS fixed header: 12 sync bits, ID, layer, protection_absent,
        // profile(2), sr_index(4), private(1), channel_config(3)...
        if (size < 7 || adts[0].toInt() != 0xFF || (adts[1].toInt() and 0xF0) != 0xF0) return
        val protectionAbsent = adts[1].toInt() and 0x1
        val srIndex = (adts[2].toInt() shr 2) and 0xF
        val channels = ((adts[2].toInt() and 0x1) shl 2) or ((adts[3].toInt() shr 6) and 0x3)
        val headerLen = if (protectionAbsent == 1) 7 else 9
        val sampleRate = ADTS_SAMPLE_RATES.getOrElse(srIndex) { 0 }
        if (sampleRate == 0 || channels == 0 || size <= headerLen) return

        if (codec == null || sampleRate != configuredSampleRate || channels != configuredChannels) {
            if (!rebuild(sampleRate, channels)) return
        }

        val c = codec ?: return
        val aac = adts.copyOfRange(headerLen, size)
        try {
            val inputIndex = c.dequeueInputBuffer(0)
            if (inputIndex >= 0) {
                val inputBuffer = c.getInputBuffer(inputIndex) ?: return
                inputBuffer.clear()
                if (aac.size > inputBuffer.remaining()) {
                    // Larger AU than buffer — shouldn't happen for AAC; drop.
                    return
                }
                inputBuffer.put(aac)
                val ptsUs = System.nanoTime() / 1000
                c.queueInputBuffer(inputIndex, 0, aac.size, ptsUs, 0)
            }
        } catch (e: Exception) {
            DiagLog.log(TAG, "audio decode feed error: ${e.message} — rebuilding")
            rebuild(sampleRate, channels)
        }
    }

    private fun rebuild(
        sampleRate: Int,
        channels: Int,
    ): Boolean {
        try {
            codec?.stop()
            codec?.release()
        } catch (_: Exception) {
        }
        codec = null
        try {
            track?.pause()
            track?.flush()
            track?.release()
        } catch (_: Exception) {
        }
        track = null

        return try {
            val format =
                MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
                    // AudioSpecificConfig: AAC-LC (2), sr index, channel config
                    val srIdx = ADTS_SAMPLE_RATES.indexOf(sampleRate)
                    setByteBuffer(
                        "csd-0",
                        java.nio.ByteBuffer.wrap(
                            byteArrayOf(
                                (((2 shl 3) or (srIdx shr 1)) and 0xFF).toByte(),
                                (((srIdx and 0x1) shl 7) or (channels shl 3)).toByte(),
                            ),
                        ),
                    )
                    setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                }
            val decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            decoder.setCallback(
                object : MediaCodec.Callback() {
                    override fun onInputBufferAvailable(
                        codec: MediaCodec,
                        index: Int,
                    ) = Unit

                    override fun onOutputBufferAvailable(
                        codec: MediaCodec,
                        index: Int,
                        info: MediaCodec.BufferInfo,
                    ) {
                        try {
                            val out = codec.getOutputBuffer(index)
                            val t = track
                            if (out != null && t != null && info.size > 0) {
                                val pcm = ByteArray(info.size)
                                out.get(pcm)
                                t.write(pcm, 0, pcm.size)
                                val n = frameCounter.incrementAndGet()
                                if (n == 1L || n % 500L == 0L) {
                                    diagLog("audio decoded frames=$n sr=$configuredSampleRate ch=$configuredChannels")
                                }
                            }
                        } catch (e: Exception) {
                            DiagLog.log(TAG, "audio output error: ${e.message}")
                        } finally {
                            try {
                                codec.releaseOutputBuffer(index, false)
                            } catch (_: Exception) {
                            }
                        }
                    }

                    override fun onError(
                        codec: MediaCodec,
                        e: MediaCodec.CodecException,
                    ) {
                        DiagLog.log(TAG, "audio codec error: ${e.message}")
                    }

                    override fun onOutputFormatChanged(
                        codec: MediaCodec,
                        format: MediaFormat,
                    ) = Unit
                },
                handler,
            )
            decoder.configure(format, null, null, 0)

            val channelConfig =
                if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
            val minBuf = AudioTrack.getMinBufferSize(sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT)
            val audioTrack =
                AudioTrack(
                    AudioManager.STREAM_MUSIC,
                    sampleRate,
                    channelConfig,
                    AudioFormat.ENCODING_PCM_16BIT,
                    // >= ~100ms of headroom
                    maxOf(minBuf * 2, sampleRate / 10 * channels * 2),
                    AudioTrack.MODE_STREAM,
                )
            audioTrack.play()

            codec = decoder
            track = audioTrack
            configuredSampleRate = sampleRate
            configuredChannels = channels
            decoder.start()
            diagLog("AudioPlayer ready: ${sampleRate}Hz ${channels}ch AAC")
            true
        } catch (e: Exception) {
            DiagLog.log(TAG, "AudioPlayer rebuild failed: ${e.message}")
            false
        }
    }

    private fun diagLog(msg: String) = DiagLog.log(TAG, msg)

    companion object {
        private const val TAG = "AudioPlayer"
        private val ADTS_SAMPLE_RATES =
            intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000)
    }
}
