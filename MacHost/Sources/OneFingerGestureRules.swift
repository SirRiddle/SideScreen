import CoreGraphics

/// The decisions of the 1-finger touch-as-trackpad model, as pure functions so
/// they are unit-tested (OneFingerGestureRulesTests). AppDelegate keeps the
/// state and the CGEvent injection and asks these what a move or a lift means.
///
/// The model (settled in 0.12.7 after 0.12.5/0.12.6 flipped it back and forth):
/// - tap → click; a second tap within 400 ms / 20 pt → double click (a third
///   tap starts over); any lift before the 600 ms long-press fires is a tap,
///   so there is no 250–600 ms dead zone
/// - move past 18 pt → scroll (with momentum after a flick)
/// - hold 600 ms, then release → right click
/// - hold 600 ms, then move → left-button drag (select text, move windows)
enum OneFingerGestureRules {
    enum MoveDecision: Equatable {
        /// Still a tap candidate: the cursor follows the finger.
        case followCursor
        /// Crossed the tap radius before the long press: becomes a scroll.
        case startScroll
        case scroll
        /// Crossed the tap radius after the long press: press the left
        /// button at the touch-down point and drag.
        case startDrag
        case drag
        case ignore
    }

    static func onMove(state: GestureState, distanceFromStart: CGFloat) -> MoveDecision {
        switch state {
        case .pending:
            return distanceFromStart > GestureThresholds.tapMaxDistance ? .startScroll : .followCursor
        case .longPressReady:
            return distanceFromStart > GestureThresholds.tapMaxDistance ? .startDrag : .ignore
        case .scrolling:
            return .scroll
        case .dragging, .penDrawing:
            return .drag
        default:
            return .ignore
        }
    }

    enum UpDecision: Equatable {
        case click
        case doubleClick
        case rightClick
        case momentum(velocityX: CGFloat, velocityY: CGFloat)
        case releaseDrag
        case nothing
    }

    /// Lifts this soon after the last scroll move keep coasting.
    static let momentumMaxLiftDelayNs: UInt64 = 50_000_000
    /// Per-event scroll delta below which a lift does not coast.
    static let momentumMinDelta: CGFloat = 2.0
    static let momentumGain: CGFloat = 6.0

    /// - Parameters:
    ///   - sinceLastTapNs: time since the previous single tap ended, or nil when
    ///     there is none to pair with (none yet, or it already formed a double).
    static func onUp(
        state: GestureState,
        distanceFromStart: CGFloat,
        sinceLastTapNs: UInt64?,
        distanceFromLastTap: CGFloat,
        sinceLastMoveNs: UInt64,
        lastScrollDeltaX: CGFloat,
        lastScrollDeltaY: CGFloat
    ) -> UpDecision {
        switch state {
        case .pending:
            // The long-press timer is the only time cutoff: a lift before it
            // fired is a tap however long it took.
            guard distanceFromStart < GestureThresholds.tapMaxDistance else { return .nothing }
            if let since = sinceLastTapNs,
               since < GestureThresholds.doubleTapMaxTime,
               distanceFromLastTap < GestureThresholds.doubleTapMaxDistance {
                return .doubleClick
            }
            return .click
        case .longPressReady:
            return .rightClick
        case .scrolling:
            guard sinceLastMoveNs < momentumMaxLiftDelayNs,
                  abs(lastScrollDeltaX) > momentumMinDelta || abs(lastScrollDeltaY) > momentumMinDelta else {
                return .nothing
            }
            return .momentum(velocityX: lastScrollDeltaX * momentumGain, velocityY: lastScrollDeltaY * momentumGain)
        case .dragging, .penDrawing:
            return .releaseDrag
        default:
            return .nothing
        }
    }
}
