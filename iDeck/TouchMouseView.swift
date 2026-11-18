import SwiftUI
import UIKit
import Darwin

/// Direct touch: a finger presses where it touches, with no cursor drawn
/// (Madeira's winios touch bridge).
struct TouchMouseView: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchMouseSurface { TouchMouseSurface() }
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

    private func moveInstallerPointer(_ touch: UITouch) {
        guard let window else { return }
        let finger = touch.location(in: window)
        var next = pointer ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        next.x = min(max(next.x + finger.x - lastFinger.x, 0), max(0, window.bounds.width - 1))
        next.y = min(max(next.y + finger.y - lastFinger.y, 0), max(0, window.bounds.height - 1))
        lastFinger = finger
        if hypot(finger.x - fingerOrigin.x, finger.y - fingerOrigin.y) > 5 { moved = true }
        guard let guest = WindowsRendererView.guestPoint(fromWindow: next) else { return }
        pointer = next
        lastGuestPoint = (Int32(guest.x.rounded()), Int32(guest.y.rounded()))
        if let p = lastGuestPoint { Self.move?(p.0, p.1) }
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
        let windowPoint = window.map { touch.location(in: $0) } ?? .zero
        if WindowsRendererView.installerTouchMapping {
            tracked = touch
            fingerOrigin = windowPoint
            lastFinger = windowPoint
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
        if WindowsRendererView.installerTouchMapping { moveInstallerPointer(touch); return }
        guard let p = guest(touch) else { return }
        lastGuestPoint = p
        Self.move?(p.0, p.1)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        tracked = nil
        if WindowsRendererView.installerTouchMapping {
            moveInstallerPointer(touch)
            if !moved, let p = lastGuestPoint { Self.down?(p.0, p.1); Self.up?(p.0, p.1) }
            lastGuestPoint = nil
            return
        }
        if let p = guest(touch) ?? lastGuestPoint { Self.up?(p.0, p.1) }
        lastGuestPoint = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if WindowsRendererView.installerTouchMapping { tracked = nil; lastGuestPoint = nil; return }
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
