import Foundation
import AVFoundation

class AudioManager {
    func configureAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            
            appendEnvironmentList("WINEDLLOVERRIDES", "mmdevapi=b")
            setenv("WINEAUDIO", "coreaudio", 1)
            ControllerAudioGuard.shared.start()
            
            return true
        } catch {
            return false
        }
    }
}

/// Game sound never plays through a game controller (DualSense, DualShock 4
/// and other controllers with a speaker or headset jack): when iOS routes
/// output to one, iDeck sends it to the device's own speaker instead.
/// iOS has no "speaker" choice for the playback category, so for that route
/// only the session uses play-and-record with the output on the speaker; it
/// records nothing. Any other route (headphones, AirPods, speakers) is left alone.
final class ControllerAudioGuard {
    static let shared = ControllerAudioGuard()
    private var observer: NSObjectProtocol?
    private var overriding = false

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.check()
        }
        check()
    }

    static func isController(_ port: AVAudioSessionPortDescription) -> Bool {
        let name = port.portName.lowercased()
        return ["dualsense", "dualshock", "wireless controller", "xbox", "controller"].contains { name.contains($0) }
    }

    private func check() {
        let session = AVAudioSession.sharedInstance()
        let onController = session.currentRoute.outputs.contains(where: Self.isController)
        do {
            if onController {
                if session.category != .playAndRecord {
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
                }
                try session.overrideOutputAudioPort(.speaker)
                if !overriding { AppLog.record("[audio] a controller took the sound output: playing on the device speaker") }
                overriding = true
            } else if overriding, !session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                overriding = false
                try session.overrideOutputAudioPort(.none)
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
        } catch {
            AppLog.record("[audio] controller output override failed: \(error.localizedDescription)")
        }
    }
}
