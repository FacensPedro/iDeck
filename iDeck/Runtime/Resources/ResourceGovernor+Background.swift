// ResourceGovernor: background, foreground and the game's audio session.
// Split from ResourceGovernor.swift (iDeck 3.0 architecture).

import AVFoundation
import Foundation
import UIKit

extension ResourceGovernor {
    func endCloseTask() {
        guard closeTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(closeTask)
        closeTask = .invalid
    }

    func enteredBackground() {
        onActivityChange?()
        // Leaving iDeck while a game closes: keep running until Wine has exited,
        // instead of suspending mid-shutdown (iOS then ended iDeck).
        if Self.closingSession {
            if closeTask == .invalid {
                closeTask = UIApplication.shared.beginBackgroundTask(withName: "iDeck.closeSession") { [weak self] in
                    self?.endCloseTask()
                }
            }
            AppLog.record("[resources] left iDeck while the game closes: finishing the close first")
            return
        }
        // The Sessions domain's level decides first (Economy pauses, Performance keeps the
        // game running); Automatic follows Settings.
        guard ResourceDomains.current.pauseInBackground ?? Self.pauseInBackground, Self.gameRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            pausedForBackground = true
            AppLog.record("[resources] game paused in the background (audio session off; iOS suspends iDeck)")
        } catch {
            AppLog.record("[resources] could not pause the game in the background: \(error.localizedDescription)")
        }
    }

    func enteringForeground() {
        if pausedForBackground {
            pausedForBackground = false
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                AppLog.record("[resources] game resumed (audio session on)")
            } catch {
                AppLog.record("[resources] audio session could not resume: \(error.localizedDescription)")
            }
        }
        onActivityChange?()
    }
}
