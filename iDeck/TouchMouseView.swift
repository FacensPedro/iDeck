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

    private weak var tracked: UITouch?

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
        Self.down?(p.0, p.1)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch), let p = guest(touch) else { return }
        Self.move?(p.0, p.1)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        tracked = nil
        if let p = guest(touch) { Self.up?(p.0, p.1) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

/// The Windows cursor Madeira draws over dialogs: kept hidden, touch is direct.
enum TouchMouseCursor {
    private typealias Show = @convention(c) (Int32) -> Void

    static func hide() {
        // Madeira reads this each time it would place the game-mode cursor.
        setenv("MADEIRA_GAME_DIALOG_CURSOR", "0", 1)
        if let symbol = NativeSymbol.address("winios_cursor_show") {
            unsafeBitCast(symbol, to: Show.self)(0)
        }
    }
}
