// Physical keyboard and mouse for Windows programs.
// The HID usage -> virtual-key table is Madeira's HardwareInput.swift
// (GPL-3.0-or-later, Copyright 2026 125hz, Madeira Converter Exception).
//
// GCKeyboard and GCMouse report raw HID transitions: one callback per key
// change and raw mouse deltas, so mouse-look keeps working at screen edges.
// Input reaches Wine only while a game session is on screen and iDeck is
// active; losing focus releases every key and button the program holds.
// "Right stick controls mouse" turns a controller's right stick into mouse
// motion (R1/L1 click) for programs without controller support.

import Foundation
import GameController
import UIKit

enum HardwareKeyMap {
    /// Windows virtual-key code for a USB HID keyboard/keypad usage (page
    /// 0x07), or nil for a key Windows has no virtual key for. Ordered exactly
    /// as the HID table is, so a gap is visible as a gap.
    static func vk(forHIDUsage u: Int) -> Int32? {
        switch u {
        // 0x04-0x1D: a-z. HID is alphabetical, VK_A..VK_Z is 0x41..0x5A.
        case 0x04...0x1D: return Int32(0x41 + (u - 0x04))
        // 0x1E-0x26: 1-9, 0x27: 0. VK_0..VK_9 are the ASCII digits.
        case 0x1E...0x26: return Int32(0x31 + (u - 0x1E))
        case 0x27: return 0x30                       // VK_0

        case 0x28: return 0x0D                       // VK_RETURN
        case 0x29: return 0x1B                       // VK_ESCAPE
        case 0x2A: return 0x08                       // VK_BACK
        case 0x2B: return 0x09                       // VK_TAB
        case 0x2C: return 0x20                       // VK_SPACE
        case 0x2D: return 0xBD                       // VK_OEM_MINUS   -
        case 0x2E: return 0xBB                       // VK_OEM_PLUS    =
        case 0x2F: return 0xDB                       // VK_OEM_4       [
        case 0x30: return 0xDD                       // VK_OEM_6       ]
        case 0x31: return 0xDC                       // VK_OEM_5       backslash
        case 0x32: return 0xDC                       // non-US # / ~ (ISO): same VK
        case 0x33: return 0xBA                       // VK_OEM_1       ;
        case 0x34: return 0xDE                       // VK_OEM_7       '
        case 0x35: return 0xC0                       // VK_OEM_3       `
        case 0x36: return 0xBC                       // VK_OEM_COMMA   ,
        case 0x37: return 0xBE                       // VK_OEM_PERIOD  .
        case 0x38: return 0xBF                       // VK_OEM_2       /
        case 0x39: return 0x14                       // VK_CAPITAL

        // 0x3A-0x45: F1-F12 -> VK_F1 (0x70) upward.
        case 0x3A...0x45: return Int32(0x70 + (u - 0x3A))

        case 0x46: return 0x2C                       // VK_SNAPSHOT (PrintScreen)
        case 0x47: return 0x91                       // VK_SCROLL
        case 0x48: return 0x13                       // VK_PAUSE
        case 0x49: return 0x2D                       // VK_INSERT
        case 0x4A: return 0x24                       // VK_HOME
        case 0x4B: return 0x21                       // VK_PRIOR (PageUp)
        case 0x4C: return 0x2E                       // VK_DELETE (forward delete)
        case 0x4D: return 0x23                       // VK_END
        case 0x4E: return 0x22                       // VK_NEXT (PageDown)
        case 0x4F: return 0x27                       // VK_RIGHT
        case 0x50: return 0x25                       // VK_LEFT
        case 0x51: return 0x28                       // VK_DOWN
        case 0x52: return 0x26                       // VK_UP

        case 0x53: return 0x90                       // VK_NUMLOCK
        case 0x54: return 0x6F                       // VK_DIVIDE
        case 0x55: return 0x6A                       // VK_MULTIPLY
        case 0x56: return 0x6D                       // VK_SUBTRACT
        case 0x57: return 0x6B                       // VK_ADD
        // Numpad Enter. Windows tells it from the main Enter only by the E0 bit
        // on its scan code; the VK is the same. The plain VK_RETURN is what
        // every program that does not read scan codes sees anyway.
        case 0x58: return 0x0D                       // VK_RETURN (numpad)
        // 0x59-0x61: keypad 1-9 -> VK_NUMPAD1 (0x61) upward. 0x62: keypad 0.
        case 0x59...0x61: return Int32(0x61 + (u - 0x59))
        case 0x62: return 0x60                       // VK_NUMPAD0
        case 0x63: return 0x6E                       // VK_DECIMAL

        case 0x64: return 0xE2                       // VK_OEM_102 (ISO < > key)
        case 0x65: return 0x5D                       // VK_APPS (menu key)
        case 0x67: return 0x92                       // VK_OEM_NEC_EQUAL (keypad =)

        // 0x68-0x73: F13-F24 -> VK_F13 (0x7C) upward.
        case 0x68...0x73: return Int32(0x7C + (u - 0x68))

        case 0x75: return 0x2F                       // VK_HELP
        case 0x77: return 0x29                       // VK_SELECT
        // 0x74/0x76/0x78-0x7E (Execute, Menu, Stop, Again, Undo, Cut, Copy,
        // Paste, Find) are deliberately unmapped: Windows has no virtual key for
        // them, and the VKs that look close (VK_OEM_AUTO, VK_OEM_ENLW) are IME
        // keys. Inventing a mapping would send an IME key to a program.
        case 0x7F: return 0xAD                       // VK_VOLUME_MUTE
        case 0x80: return 0xAF                       // VK_VOLUME_UP
        case 0x81: return 0xAE                       // VK_VOLUME_DOWN
        case 0x85: return 0x6C                       // VK_SEPARATOR (keypad ,)

        // International / IME keys. Japanese and Korean keyboards send these
        // and a Windows program's text entry reads them.
        case 0x87: return 0xC1                       // VK_ABNT_C1 / JIS ro
        case 0x88: return 0xF2                       // VK_OEM_COPY (katakana/hiragana)
        case 0x89: return 0xDC                       // JIS yen: VK_OEM_5
        case 0x8A: return 0x1C                       // VK_CONVERT
        case 0x8B: return 0x1D                       // VK_NONCONVERT
        case 0x90: return 0x15                       // VK_HANGUL
        case 0x91: return 0x19                       // VK_HANJA

        // 0xE0-0xE7: the modifiers, as ordinary keys with LEFT/RIGHT identity.
        case 0xE0: return 0xA2                       // VK_LCONTROL
        case 0xE1: return 0xA0                       // VK_LSHIFT
        case 0xE2: return 0xA4                       // VK_LMENU
        case 0xE3: return 0x5B                       // VK_LWIN
        case 0xE4: return 0xA3                       // VK_RCONTROL
        case 0xE5: return 0xA1                       // VK_RSHIFT
        case 0xE6: return 0xA5                       // VK_RMENU
        case 0xE7: return 0x5C                       // VK_RWIN

        default: return nil
        }
    }
}

@MainActor
final class HardwareInput: ObservableObject {
    static let shared = HardwareInput()

    static let mouseSensitivityKey = "input.mouseSensitivity"
    static let stickMouseKey = "input.rightStickMouse"
    static let enabledKey = "input.keyboardMouse"

    @Published private(set) var keyboardName: String?
    @Published private(set) var mouseName: String?

    /// Set by the game session view while it is on screen.
    var sessionVisible = false {
        didSet { if !sessionVisible { releaseAll() } }
    }

    private var heldKeys = Set<Int32>()
    private var heldButtons = Set<UInt32>()
    private var stickTimer: Timer?
    private var started = false

    private typealias PostKey = @convention(c) (Int32, Int32) -> Void
    private typealias Pointer = @convention(c) (Int32, Int32, UInt32, UInt32) -> Void
    private let postKeySymbol: PostKey? = HardwareInput.symbol("winios_post_key")
    private let pointerSymbol: Pointer? = HardwareInput.symbol("winios_pointer")

    private static func symbol<T>(_ name: String) -> T? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    private var sensitivity: Double {
        let value = UserDefaults.standard.double(forKey: Self.mouseSensitivityKey)
        return value > 0 ? value : 1.0
    }

    private var hasFocus: Bool {
        enabled && sessionVisible && UIApplication.shared.applicationState == .active && ideck_wineprocess_running()
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachKeyboard() }
        }
        center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardName = nil; self?.releaseAll() }
        }
        center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachMice() }
        }
        center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachMice() }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAll() }
        }
        attachKeyboard()
        attachMice()
        stickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stickTick() }
        }
    }

    // MARK: Keyboard

    private func attachKeyboard() {
        guard let keyboard = GCKeyboard.coalesced else { keyboardName = nil; return }
        keyboardName = keyboard.vendorName ?? tr("Keyboard")
        keyboard.keyboardInput?.keyChangedHandler = { _, _, code, pressed in
            let usage = Int(code.rawValue)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HardwareInput.shared.key(usage: usage, pressed: pressed) }
            }
        }
    }

    private func key(usage: Int, pressed: Bool) {
        guard let vk = HardwareKeyMap.vk(forHIDUsage: usage) else { return }
        if pressed {
            // A key pressed while the program had no focus stays away from it.
            guard hasFocus, heldKeys.insert(vk).inserted else { return }
            postKeySymbol?(vk, 1)
        } else if heldKeys.remove(vk) != nil {
            postKeySymbol?(vk, 0)
        }
    }

    // MARK: Mouse

    private func attachMice() {
        mouseName = GCMouse.mice().first.map { $0.vendorName ?? tr("Mouse") }
        for mouse in GCMouse.mice() {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = { _, dx, dy in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { HardwareInput.shared.move(dx: Double(dx), dy: Double(-dy)) }
                }
            }
            input.leftButton.pressedChangedHandler = { _, _, pressed in
                DispatchQueue.main.async { MainActor.assumeIsolated { HardwareInput.shared.button(0x0002, pressed: pressed) } }
            }
            input.rightButton?.pressedChangedHandler = { _, _, pressed in
                DispatchQueue.main.async { MainActor.assumeIsolated { HardwareInput.shared.button(0x0008, pressed: pressed) } }
            }
            input.middleButton?.pressedChangedHandler = { _, _, pressed in
                DispatchQueue.main.async { MainActor.assumeIsolated { HardwareInput.shared.button(0x0020, pressed: pressed) } }
            }
            input.scroll.valueChangedHandler = { _, x, y in
                DispatchQueue.main.async { MainActor.assumeIsolated { HardwareInput.shared.scroll(x: Double(x), y: Double(y)) } }
            }
        }
    }

    private var remainderX = 0.0
    private var remainderY = 0.0

    private func move(dx: Double, dy: Double) {
        guard hasFocus else { return }
        remainderX += dx * sensitivity
        remainderY += dy * sensitivity
        let x = Int32(remainderX.rounded(.towardZero))
        let y = Int32(remainderY.rounded(.towardZero))
        guard x != 0 || y != 0 else { return }
        remainderX -= Double(x)
        remainderY -= Double(y)
        pointerSymbol?(x, y, 0x0001, 0)          // MOUSEEVENTF_MOVE, relative
    }

    /// `downFlag` is the MOUSEEVENTF_*DOWN flag; its UP flag is the next bit.
    private func button(_ downFlag: UInt32, pressed: Bool) {
        if pressed {
            guard hasFocus, heldButtons.insert(downFlag).inserted else { return }
            pointerSymbol?(0, 0, downFlag, 0)
        } else if heldButtons.remove(downFlag) != nil {
            pointerSymbol?(0, 0, downFlag << 1, 0)
        }
    }

    private func scroll(x: Double, y: Double) {
        guard hasFocus else { return }
        if y != 0 { pointerSymbol?(0, 0, 0x0800, UInt32(bitPattern: Int32(y * 120))) }   // MOUSEEVENTF_WHEEL
        if x != 0 { pointerSymbol?(0, 0, 0x1000, UInt32(bitPattern: Int32(x * 120))) }   // MOUSEEVENTF_HWHEEL
    }

    // MARK: Right stick as mouse

    private var stickButtons = (left: false, right: false)

    private func stickTick() {
        guard UserDefaults.standard.bool(forKey: Self.stickMouseKey), hasFocus,
              let pad = GCController.controllers().first?.extendedGamepad else { return }
        let x = Double(pad.rightThumbstick.xAxis.value)
        let y = Double(pad.rightThumbstick.yAxis.value)
        let magnitude = (x * x + y * y).squareRoot()
        if magnitude > 0.15 {
            // Quadratic response: fine aim near the centre, fast at the edge.
            let speed = 18.0 * sensitivity * magnitude
            move(dx: x / magnitude * speed * magnitude, dy: -y / magnitude * speed * magnitude)
        }
        let right = pad.rightShoulder.isPressed
        let left = pad.leftShoulder.isPressed
        if right != stickButtons.right { button(0x0002, pressed: right); stickButtons.right = right }
        if left != stickButtons.left { button(0x0008, pressed: left); stickButtons.left = left }
    }

    // MARK: Focus

    func releaseAll() {
        for vk in heldKeys { postKeySymbol?(vk, 0) }
        heldKeys.removeAll()
        for flag in heldButtons { pointerSymbol?(0, 0, flag << 1, 0) }
        heldButtons.removeAll()
        stickButtons = (false, false)
    }
}
