import XCTest
@testable import SideScreen

/// Issues #91 / #100: adb installed outside the few hard-coded paths (nix-darwin,
/// custom SDK locations) showed "ADB: Missing".
final class ADBLocatorTests: XCTestCase {
    private let home = "/Users/tester"

    private func candidates(custom: String? = nil, env: [String: String] = [:]) -> [String] {
        ADBLocator.candidates(customPath: custom, environment: env, home: home, user: "tester")
    }

    func testCustomPathComesFirst() {
        let paths = candidates(custom: "/opt/android/platform-tools/adb")
        XCTAssertEqual(paths.first, "/opt/android/platform-tools/adb")
    }

    func testCustomDirectoryAlsoTriesAdbInside() {
        let paths = candidates(custom: "~/sdk/platform-tools/")
        XCTAssertEqual(Array(paths.prefix(2)), ["/Users/tester/sdk/platform-tools", "/Users/tester/sdk/platform-tools/adb"])
    }

    func testEmptyOrRelativeCustomPathIsIgnored() {
        XCTAssertNil(ADBLocator.normalizedCustomPath("   ", home: home))
        XCTAssertNil(ADBLocator.normalizedCustomPath(nil, home: home))
        XCTAssertNil(ADBLocator.normalizedCustomPath("bin/adb", home: home))
        XCTAssertEqual(candidates(custom: "").first, "/opt/homebrew/bin/adb")
    }

    func testAndroidHomeBeatsWellKnownLocations() {
        let paths = candidates(env: ["ANDROID_HOME": "/sdk", "ANDROID_SDK_ROOT": "/other"])
        XCTAssertEqual(Array(paths.prefix(2)), ["/sdk/platform-tools/adb", "/other/platform-tools/adb"])
    }

    func testNixDarwinAndHomebrewLocationsAreSearched() {
        let paths = candidates()
        for expected in [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/Users/tester/Library/Android/sdk/platform-tools/adb",
            "/run/current-system/sw/bin/adb",
            "/etc/profiles/per-user/tester/bin/adb",
            "/Users/tester/.nix-profile/bin/adb",
        ] {
            XCTAssertTrue(paths.contains(expected), "missing \(expected)")
        }
        XCTAssertEqual(paths.count, Set(paths).count, "no duplicates")
    }

    func testShellLookupTakesTheLastPathLine() {
        let output = "Welcome to zsh!\n/run/current-system/sw/bin/adb\n"
        XCTAssertEqual(ADBLocator.parseShellLookup(output), "/run/current-system/sw/bin/adb")
        XCTAssertNil(ADBLocator.parseShellLookup(""))
        XCTAssertNil(ADBLocator.parseShellLookup("adb not found\n"))
    }

    func testLoginShellDefaultsToZsh() {
        XCTAssertEqual(ADBLocator.loginShell(environment: [:]), "/bin/zsh")
        XCTAssertEqual(ADBLocator.loginShell(environment: ["SHELL": "/opt/homebrew/bin/fish"]), "/opt/homebrew/bin/fish")
        XCTAssertEqual(ADBLocator.loginShell(environment: ["SHELL": "fish"]), "/bin/zsh")
    }
}
