import XCTest
@testable import SideScreen

/// Issue #108: the virtual display's identity (→ macOS display UUID, which keys
/// wallpaper and arrangement) must survive a resolution change.
final class VirtualDisplayIdentityTests: XCTestCase {
    private func id(_ w: Int, _ h: Int, hiDPI: Bool = false) -> UInt32 {
        VirtualDisplayManager.productID(physicalWidth: w, physicalHeight: h, hiDPI: hiDPI)
    }

    func testResolutionChangeKeepsTheIdentity() {
        XCTAssertEqual(id(1920, 1200), id(2560, 1600))
        XCTAssertEqual(id(3840, 2400, hiDPI: true), id(5120, 3200, hiDPI: true))
        XCTAssertEqual(id(1600, 1066), id(1920, 1280), "custom 3:2 sizes from #108")
    }

    func testPortraitAndLandscapeStayDistinct() {
        // The collision the old W×H encoding existed to prevent.
        XCTAssertNotEqual(id(3840, 2400), id(2400, 3840))
    }

    func testHiDPIIsADifferentDisplay() {
        XCTAssertNotEqual(id(3840, 2400, hiDPI: true), id(3840, 2400, hiDPI: false))
    }

    func testSquarePanelsCountAsLandscape() {
        XCTAssertEqual(id(2000, 2000), id(1920, 1200))
    }
}
