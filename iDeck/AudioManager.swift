import Foundation
import AVFoundation

class AudioManager {
    func configureAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            
            setenv("WINEDLLOVERRIDES", String(cString: getenv("WINEDLLOVERRIDES")) + ";mmdevapi=b", 1)
            setenv("WINEAUDIO", "coreaudio", 1)
            
            return true
        } catch {
            return false
        }
    }
}
