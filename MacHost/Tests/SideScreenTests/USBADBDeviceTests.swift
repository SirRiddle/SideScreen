import XCTest
@testable import SideScreen

/// Device parsing from upstream PR #80 (by @aytekaksu), on top of #102's
/// per-serial adb reverse: only physical USB devices get a tunnel.
final class USBADBDeviceTests: XCTestCase {
    private let mixedDevices = """
    List of devices attached
    TABLET_A               device usb:2-2 product:tablet_a model:Test_Tablet device:tablet_a transport_id:17
    emulator-5580          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:26
    192.0.2.12:5555        device product:tablet model:Wireless_Tablet device:tablet transport_id:28
    OTHER                  unauthorized usb:2-3 transport_id:29
    """

    func testPhysicalDevicesAreListedWithTheirState() {
        XCTAssertEqual(USBADBDevice.parse(mixedDevices), [
            USBADBDevice(serial: "TABLET_A", model: "Test_Tablet"),
            USBADBDevice(serial: "OTHER", model: nil, state: "unauthorized")
        ])
    }

    func testLibusbOutputKeepsUSBDevicesAndExcludesNetworkTransports() {
        let output = """
        * daemon started successfully *
        List of devices attached
        USB123 device product:tablet model:Test_Tablet transport_id:1
        emulator-5554 device model:Emulator transport_id:2
        192.0.2.12:5555 device model:WiFi transport_id:3
        [2001:db8::1]:5555 device model:WiFi transport_id:4
        tablet.local:5555 device model:WiFi transport_id:5
        adb-USB123-example._adb-tls-connect._tcp device model:WiFi transport_id:6
        """
        XCTAssertEqual(USBADBDevice.parse(output), [USBADBDevice(serial: "USB123", model: "Test_Tablet")])
    }

    func testUnavailableDevicesCarryActionableHints() {
        let devices = USBADBDevice.parse("A unauthorized transport_id:1\nB offline usb:2-3 transport_id:2")
        XCTAssertEqual(devices.map(\.state), ["unauthorized", "offline"])
        XCTAssertTrue(devices.allSatisfy { !$0.isReady })
        XCTAssertEqual(devices[0].connectionHint, "Allow USB debugging on Android device (A).")
        XCTAssertEqual(devices[1].connectionHint, "Android device (B) is offline. Reconnect its USB cable.")
    }

    func testReadyDeviceHasNoHintAndReadableName() {
        let device = USBADBDevice(serial: "R5CW", model: "Galaxy_Tab_S9")
        XCTAssertNil(device.connectionHint)
        XCTAssertEqual(device.displayName, "Galaxy Tab S9 (R5CW)")
    }
}
