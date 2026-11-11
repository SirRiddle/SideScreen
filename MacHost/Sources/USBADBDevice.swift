import Foundation

/// One line of `adb devices -l` that is a physical USB device (from upstream
/// PR #80 by @aytekaksu). Emulators, `adb connect` (ip:port) and mDNS / TLS
/// wireless-debugging transports are excluded: `adb reverse` on them would
/// tunnel the stream to the wrong device. Unauthorized / offline devices are
/// kept so the UI can say what to do about them.
struct USBADBDevice: Equatable, Identifiable {
    let serial: String
    let model: String?
    var state: String = "device"

    var id: String { serial }
    var isReady: Bool { state == "device" }

    var displayName: String {
        let name = model?.replacingOccurrences(of: "_", with: " ") ?? "Android device"
        return "\(name) (\(serial))"
    }

    /// What the user should do about a device that is attached but unusable.
    var connectionHint: String? {
        switch state {
        case "unauthorized": return "Allow USB debugging on \(displayName)."
        case "offline": return "\(displayName) is offline. Reconnect its USB cable."
        default: return nil
        }
    }

    /// libusb omits `usb:`, so exclude ADB's emulator, socket and mDNS serial
    /// formats instead of requiring the native USB backend's optional marker.
    static func parse(_ output: String) -> [USBADBDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, ["device", "unauthorized", "offline"].contains(fields[1]),
                  !fields[0].hasPrefix("emulator-"), !fields[0].contains(":"),
                  !fields[0].contains("._tcp") else {
                return nil
            }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)) }
            return USBADBDevice(serial: fields[0], model: model, state: fields[1])
        }
    }
}
