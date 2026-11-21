import SwiftUI
import UIKit
import Darwin

/// Direct touch: a finger presses where it touches, with no cursor drawn
/// (Madeira's winios touch bridge).
struct TouchMouseView: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchMouseSurface { TouchMouseSurface() }
    static func dismantleUIView(_ view: TouchMouseSurface, coordinator: ()) {
        view.releaseInstallerClick()
    }
    func updateUIView(_ uiView: TouchMouseSurface, context: Context) {}
}

final class TouchMouseSurface: UIView {
    private typealias Post = @convention(c) (Int32, Int32) -> Void
    private static func symbol(_ name: String) -> Post? {
        NativeSymbol.address(name).map { unsafeBitCast($0, to: Post.self) }
    }
    private static let down = symbol("winios_post_touch_down")
    private static let move = symbol("winios_post_touch_move")
    private static let up = symbol("winios_post_touch_up")

    private var pointer: CGPoint?
    private var fingerOrigin = CGPoint.zero
    private var lastFinger = CGPoint.zero
    private var moved = false
    private var touchStarted: TimeInterval = 0

    /// More than 30 pt from where the finger came down: a drag even when quick.
    private func draggedFar(_ touch: UITouch) -> Bool {
        guard let window else { return false }
        let p = touch.location(in: window)
        return hypot(p.x - fingerOrigin.x, p.y - fingerOrigin.y) > 30
    }

    private func moveInstallerPointer(_ touch: UITouch) {
        guard let window else { return }
        let finger = touch.location(in: window)
        var next = pointer ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        next.x = min(max(next.x + finger.x - lastFinger.x, 0), max(0, window.bounds.width - 1))
        next.y = min(max(next.y + finger.y - lastFinger.y, 0), max(0, window.bounds.height - 1))
        lastFinger = finger
        // A tap drifts a few points while the finger rests and lifts: only a real
        // drag (more than 12 pt) stops it from being a click.
        if hypot(finger.x - fingerOrigin.x, finger.y - fingerOrigin.y) > 12 { moved = true }
        guard let guest = WindowsRendererView.guestPoint(fromWindow: next) else { return }
        pointer = next
        lastGuestPoint = (Int32(guest.x.rounded()), Int32(guest.y.rounded()))
        if let p = lastGuestPoint { Self.move?(p.0, p.1) }
    }

    private var pendingRelease: DispatchWorkItem?
    private var pressedPoint: (Int32, Int32)?

    private var downSent = false

    fileprivate func releaseInstallerClick() {
        pendingRelease?.cancel()
        pendingRelease = nil
        guard let point = pressedPoint else { return }
        pressedPoint = nil
        if downSent { Self.up?(point.0, point.1) }
        downSent = false
    }

    private func clickInstallerPointer(at point: (Int32, Int32)) {
        // The cursor is put on the button first, and the press comes a frame later:
        // a press posted together with the move reached the dialog before the
        // pointer was over the button, so the click landed nowhere.
        Self.move?(point.0, point.1)
        pressedPoint = point
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            guard let self, let pressed = self.pressedPoint, pressed == point else { return }
            Self.down?(point.0, point.1)
            self.downSent = true
            // Hold it long enough for the dialog's input loop to see the press.
            let release = DispatchWorkItem { [weak self] in self?.releaseInstallerClick() }
            self.pendingRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90), execute: release)
        }
    }

    private weak var tracked: UITouch?
    private var lastGuestPoint: (Int32, Int32)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }
    required init?(coder: NSCoder) { nil }

    private func guest(_ touch: UITouch) -> (Int32, Int32)? {
        guard let window else { return nil }
        let point = touch.location(in: window)
        guard let g = WindowsRendererView.guestPoint(fromWindow: point) else { return nil }
        return (Int32(g.x.rounded()), Int32(g.y.rounded()))
    }

    /// The first taps of each run are logged with where they were mapped, so a bug
    /// report shows whether a tap that "did nothing" landed on the button.
    private static var loggedTaps = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let touch = touches.first else { return }
        releaseInstallerClick()
        let windowPoint = window.map { touch.location(in: $0) } ?? .zero
        if WindowsRendererView.installerTouchMapping && touch.type != .indirectPointer {
            tracked = touch
            fingerOrigin = windowPoint
            lastFinger = windowPoint
            touchStarted = touch.timestamp
            moved = false
            moveInstallerPointer(touch)
            return
        }
        guard let p = guest(touch) else {
            if Self.loggedTaps < 12 {
                Self.loggedTaps += 1
                AppLog.record("[touch] tap at \(Int(windowPoint.x)),\(Int(windowPoint.y)) dropped: no game surface to map it onto")
            }
            return
        }
        if Self.loggedTaps < 12 {
            Self.loggedTaps += 1
            AppLog.record("[touch] tap at \(Int(windowPoint.x)),\(Int(windowPoint.y)) -> guest \(p.0),\(p.1) "
                          + "(\(WindowsRendererView.touchMappingSummary)); down=\(Self.down != nil)")
        }
        tracked = touch
        lastGuestPoint = p
        Self.move?(p.0, p.1)
        Self.down?(p.0, p.1)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        if WindowsRendererView.installerTouchMapping && touch.type != .indirectPointer { moveInstallerPointer(touch); return }
        guard let p = guest(touch) else { return }
        lastGuestPoint = p
        Self.move?(p.0, p.1)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        tracked = nil
        if WindowsRendererView.installerTouchMapping && touch.type != .indirectPointer {
            // No last move here: the lift itself must not push the cursor off target.
            let quick = touch.timestamp - touchStarted < 0.35
            if !moved || quick && !draggedFar(touch), let p = lastGuestPoint { clickInstallerPointer(at: p) }
            lastGuestPoint = nil
            return
        }
        if let p = guest(touch) ?? lastGuestPoint { Self.up?(p.0, p.1) }
        lastGuestPoint = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if WindowsRendererView.installerTouchMapping && tracked?.type != .indirectPointer { tracked = nil; lastGuestPoint = nil; return }
        touchesEnded(touches, with: event)
    }
}

/// The Windows cursor Madeira draws over dialogs: kept hidden, touch is direct.
enum TouchMouseCursor {
    private typealias Show = @convention(c) (Int32) -> Void

    static func setVisible(_ visible: Bool) {
        // Madeira reads this each time it would place the game-mode cursor.
        setenv("MADEIRA_GAME_DIALOG_CURSOR", visible ? "1" : "0", 1)
        if let symbol = NativeSymbol.address("winios_cursor_show") {
            unsafeBitCast(symbol, to: Show.self)(visible ? 1 : 0)
        }
    }
}
