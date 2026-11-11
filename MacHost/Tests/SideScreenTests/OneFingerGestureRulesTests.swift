import XCTest
import CoreGraphics
@testable import SideScreen

/// Locks in the 1-finger model settled in 0.12.7 (0.12.5 and 0.12.6 flipped it
/// back and forth in one day): move = scroll, hold-then-move = drag, hold-then-
/// release = right click, any lift before the long press = tap.
final class OneFingerGestureRulesTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let tapRadius = GestureThresholds.tapMaxDistance

    private func up(
        _ state: GestureState,
        moved: CGFloat = 0,
        sinceLastTapMs: UInt64? = nil,
        fromLastTap: CGFloat = 0,
        sinceLastMoveMs: UInt64 = 500,
        lastDelta: (CGFloat, CGFloat) = (0, 0)
    ) -> OneFingerGestureRules.UpDecision {
        OneFingerGestureRules.onUp(
            state: state,
            lift: OneFingerGestureRules.Lift(
                distanceFromStart: moved,
                sinceLastTapNs: sinceLastTapMs.map { $0 * ms },
                distanceFromLastTap: fromLastTap,
                sinceLastMoveNs: sinceLastMoveMs * ms,
                lastScrollDeltaX: lastDelta.0,
                lastScrollDeltaY: lastDelta.1
            )
        )
    }

    // MARK: - Moves

    func testSmallMovementBeforeLongPressMovesTheCursor() {
        XCTAssertEqual(OneFingerGestureRules.onMove(state: .pending, distanceFromStart: tapRadius - 1), .followCursor)
    }

    func testOneFingerMoveScrolls() {
        XCTAssertEqual(OneFingerGestureRules.onMove(state: .pending, distanceFromStart: tapRadius + 1), .startScroll)
        XCTAssertEqual(OneFingerGestureRules.onMove(state: .scrolling, distanceFromStart: 400), .scroll)
    }

    func testHoldThenMoveDragsWithTheLeftButton() {
        XCTAssertEqual(OneFingerGestureRules.onMove(state: .longPressReady, distanceFromStart: tapRadius - 1), .ignore)
        XCTAssertEqual(OneFingerGestureRules.onMove(state: .longPressReady, distanceFromStart: tapRadius + 1), .startDrag)
        XCTAssertEqual(OneFingerGestureRules.onMove(state: .dragging, distanceFromStart: 300), .drag)
    }

    func testIdleMovesAreIgnored() {
        XCTAssertEqual(OneFingerGestureRules.onMove(state: .idle, distanceFromStart: 100), .ignore)
    }

    // MARK: - Lifts

    func testTapClicks() {
        XCTAssertEqual(up(.pending), .click)
    }

    func testNoDeadZoneBetweenTapTimeAndLongPress() {
        // A press of any length that is still .pending (long press not fired)
        // is a tap — 0.12.3 removed a 250–600 ms window that produced nothing.
        XCTAssertEqual(up(.pending, moved: tapRadius - 1), .click)
    }

    func testSecondTapNearbyAndSoonDoubleClicks() {
        XCTAssertEqual(up(.pending, sinceLastTapMs: 200, fromLastTap: 5), .doubleClick)
    }

    func testSecondTapTooLateOrTooFarIsAnotherClick() {
        let late = GestureThresholds.doubleTapMaxTime / ms + 1
        XCTAssertEqual(up(.pending, sinceLastTapMs: late, fromLastTap: 5), .click)
        XCTAssertEqual(up(.pending, sinceLastTapMs: 200, fromLastTap: GestureThresholds.doubleTapMaxDistance + 1), .click)
    }

    func testThirdTapStartsOverAfterADoubleClick() {
        // After a double click the caller clears the last tap (nil here).
        XCTAssertEqual(up(.pending, sinceLastTapMs: nil, fromLastTap: 0), .click)
    }

    func testLiftAfterMovingPastTheTapRadiusIsNotATap() {
        XCTAssertEqual(up(.pending, moved: tapRadius + 1), .nothing)
    }

    func testHoldThenReleaseRightClicks() {
        XCTAssertEqual(up(.longPressReady), .rightClick)
    }

    func testDragEndsByReleasingTheButton() {
        XCTAssertEqual(up(.dragging, moved: 300), .releaseDrag)
        XCTAssertEqual(up(.penDrawing, moved: 300), .releaseDrag, "mode switched off mid-stroke must not strand the button")
    }

    func testFlickCoastsSlowLiftStops() {
        XCTAssertEqual(
            up(.scrolling, sinceLastMoveMs: 10, lastDelta: (0, 10)),
            .momentum(velocityX: 0, velocityY: 10 * OneFingerGestureRules.momentumGain)
        )
        XCTAssertEqual(up(.scrolling, sinceLastMoveMs: 80, lastDelta: (0, 10)), .nothing, "finger rested before lifting")
        XCTAssertEqual(up(.scrolling, sinceLastMoveMs: 10, lastDelta: (1, 1)), .nothing, "too slow to coast")
    }

    func testThresholdsMatchTheDocumentedModel() {
        XCTAssertEqual(GestureThresholds.longPressTime, 600 * ms)
        XCTAssertEqual(GestureThresholds.doubleTapMaxTime, 400 * ms)
        XCTAssertEqual(GestureThresholds.tapMaxDistance, 18)
    }
}
