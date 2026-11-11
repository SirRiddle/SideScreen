import Foundation
import SystemConfiguration

enum StatusDetector {
    static func adbInstalled() -> Bool {
        return adbExecutablePath() != nil
    }

    static func wifiReachable() -> Bool {
        guard let reach = SCNetworkReachabilityCreateWithName(nil, "1.1.1.1") else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reach, &flags) else { return false }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }

    /// Run `adb devices`, return list of device serials in `device` state.
    static func usbDevices() -> [String] {
        guard let adbPath = adbExecutablePath() else { return [] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["devices"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2, parts[1] == "device" else { return nil }
            return parts[0]
        }
    }

    /// Heuristic: parse `adb reverse --list` for `tcp:<port> tcp:<port>`.
    /// `serial` targets one device; without it adb refuses as soon as two
    /// devices are attached ("more than one device").
    static func adbReverseConfigured(port: Int, serial: String? = nil) -> Bool {
        guard let adbPath = adbExecutablePath() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = (serial.map { ["-s", $0] } ?? []) + ["reverse", "--list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.contains("tcp:\(port) tcp:\(port)")
    }

    private static let adbLock = NSLock()
    private static var cachedAdbPath: String?
    private static var lastAdbCacheCheck: Date = .distantPast
    /// Result of the login-shell PATH lookup, refreshed off the main thread.
    private static var shellAdbPath: String?
    private static var lastShellLookup: Date = .distantPast
    private static var shellLookupRunning = false

    /// Path of the adb executable, or nil. Cheap and safe on the main thread:
    /// the fixed candidates (ADBLocator) are re-checked every 5 s; the
    /// login-shell PATH lookup runs in the background at most once a minute.
    static func adbExecutablePath() -> String? {
        adbLock.lock()
        if let cached = cachedAdbPath, Date().timeIntervalSince(lastAdbCacheCheck) < 5.0 {
            adbLock.unlock()
            return cached
        }
        adbLock.unlock()

        let env = ProcessInfo.processInfo.environment
        let candidates = ADBLocator.candidates(
            customPath: UserDefaults.standard.string(forKey: ADBLocator.customPathKey),
            environment: env,
            home: NSHomeDirectory(),
            user: NSUserName()
        )
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? shellLookupResult(environment: env)

        adbLock.lock()
        cachedAdbPath = found
        lastAdbCacheCheck = Date()
        adbLock.unlock()
        return found
    }

    /// adb as the user's login shell finds it (nix-darwin, asdf, custom PATH).
    /// Returns the last known result at once and refreshes it in the
    /// background when older than a minute, so status polling never blocks.
    private static func shellLookupResult(environment: [String: String]) -> String? {
        adbLock.lock()
        let result = shellAdbPath.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        let stale = Date().timeIntervalSince(lastShellLookup) > 60
        let start = stale && !shellLookupRunning
        if start { shellLookupRunning = true }
        adbLock.unlock()

        if start {
            DispatchQueue.global(qos: .utility).async {
                let path = runShellLookup(shell: ADBLocator.loginShell(environment: environment))
                adbLock.lock()
                shellAdbPath = path
                lastShellLookup = Date()
                shellLookupRunning = false
                if path != nil { lastAdbCacheCheck = .distantPast } // pick it up on the next call
                adbLock.unlock()
                if let path { debugLog("Found adb via login shell PATH: \(path)") }
            }
        }
        return result
    }

    /// `<shell> -l -c 'command -v adb'`, killed after 3 s (a slow or
    /// interactive startup file must not hang the lookup).
    private static func runShellLookup(shell: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-l", "-c", "command -v adb"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do {
            try task.run()
        } catch {
            return nil
        }
        if done.wait(timeout: .now() + 3) == .timedOut {
            task.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
              let path = ADBLocator.parseShellLookup(output),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
