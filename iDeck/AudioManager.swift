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
            
            return true
        } catch {
            return false
        }
    }
}
