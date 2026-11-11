import Foundation

/// Where to look for `adb` (issues #91, #100). A GUI app gets launchd's PATH
/// (/usr/bin:/bin:/usr/sbin:/sbin), not the user's shell PATH, so `which adb`
/// misses nix-darwin, asdf, MacPorts and custom SDK locations. Pure, so the
/// order is unit-tested; StatusDetector does the file-system checks.
enum ADBLocator {
    /// UserDefaults key for the user's own adb path (Settings → ADB path).
    static let customPathKey = "SideScreen_adbPath"

    /// Candidate executables, most specific first: the user's setting, the
    /// SDK the environment points at, then well-known install locations.
    static func candidates(
        customPath: String?,
        environment: [String: String],
        home: String,
        user: String
    ) -> [String] {
        var paths: [String] = []
        if let custom = normalizedCustomPath(customPath, home: home) {
            paths.append(custom)
            if !custom.hasSuffix("/adb") {
                paths.append((custom as NSString).appendingPathComponent("adb"))
            }
        }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = environment[key], !sdk.isEmpty {
                paths.append((sdk as NSString).appendingPathComponent("platform-tools/adb"))
            }
        }
        paths += [
            "/opt/homebrew/bin/adb",                                   // Homebrew (Apple Silicon)
            "/usr/local/bin/adb",                                      // Homebrew (Intel), manual installs
            "\(home)/Library/Android/sdk/platform-tools/adb",          // Android Studio
            "/run/current-system/sw/bin/adb",                          // nix-darwin system packages (#91)
            "/etc/profiles/per-user/\(user)/bin/adb",                  // nix-darwin / home-manager per-user
            "\(home)/.nix-profile/bin/adb",                            // nix profile
            "/nix/var/nix/profiles/default/bin/adb",                   // nix default profile
            "/opt/local/bin/adb"                                       // MacPorts
        ]
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// The setting as an absolute path: trimmed, `~` expanded, nil when empty.
    /// A directory (e.g. an SDK's platform-tools) is allowed; `candidates`
    /// also tries `<dir>/adb`.
    static func normalizedCustomPath(_ raw: String?, home: String) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        var path = trimmed
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + String(path.dropFirst(1))
        }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path.hasPrefix("/") ? path : nil
    }

    /// The path printed by `command -v adb` in a login shell. Shell startup
    /// files may print banners, so take the last absolute path line.
    static func parseShellLookup(_ output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && $0.hasSuffix("adb") }
    }

    /// The user's login shell for the PATH lookup; zsh (the macOS default)
    /// unless $SHELL names an absolute path.
    static func loginShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"], shell.hasPrefix("/") {
            return shell
        }
        return "/bin/zsh"
    }
}
