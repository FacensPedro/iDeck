// Background downloads for every store (Steam, GOG, Epic).
// Adapted from Madeira's SteamDownloadBackground.swift
// (GPL-3.0-or-later, Copyright 2026 125hz, Madeira Converter Exception).
//
// iOS 26+: a BGContinuedProcessingTask keeps iDeck running for the whole
// queue while iOS shows its own progress UI. When iOS refuses or expires it,
// the short background grace period runs, then downloads pause cleanly
// (finished chunks are journaled) and resume when iDeck is active again.
// A local notification reports finished, failed and paused downloads.

import UIKit
import BackgroundTasks
import UserNotifications

@MainActor
final class BackgroundDownloads {
    static let steam = BackgroundDownloads(source: "Steam", suffix: "queue")
    static let gog = BackgroundDownloads(source: "GOG", suffix: "gog")
    static let epic = BackgroundDownloads(source: "Epic Games", suffix: "epic")

    static let continuedKey = "downloads.continueInBackground"
    static let notificationsKey = "downloads.notifications"

    static var continuedEnabled: Bool {
        UserDefaults.standard.object(forKey: continuedKey) as? Bool ?? true
    }
    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notificationsKey) as? Bool ?? true
    }

    enum Outcome { case completed, failed(String), paused }

    private let source: String
    private let suffix: String
    private var isActive: () -> Bool = { false }
    private var pause: () -> Void = {}
    private var resume: () -> Void = {}

    private var graceTask: UIBackgroundTaskIdentifier = .invalid
    private var continued: AnyObject?
    private var continuedPending = false
    private var registered = false
    private var observing = false
    private var currentName = ""
    private var logged = 0

    private init(source: String, suffix: String) {
        self.source = source
        self.suffix = suffix
    }

    private func log(_ line: String) {
        guard logged < 48 else { return }
        logged += 1
        AppLog.record("[bg-download] \(source): \(line)")
    }

    private var isBackground: Bool { UIApplication.shared.applicationState != .active }

    /// "<bundle id>.download.<suffix>", allowed by the
    /// "$(PRODUCT_BUNDLE_IDENTIFIER).download.*" entry in Info.plist.
    private var taskIdentifier: String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let wildcard = permitted.first(where: { $0.hasSuffix(".download.*") }) else { return nil }
        return String(wildcard.dropLast()) + suffix
    }

    /// Connects a download queue. Called once per store.
    func attach(active: @escaping () -> Bool, pause: @escaping () -> Void, resume: @escaping () -> Void) {
        isActive = active
        self.pause = pause
        self.resume = resume
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginGrace() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endGrace()
                self?.resume()
            }
        }
    }

    func started(name: String) {
        currentName = name
        requestNotificationPermission()
        if #available(iOS 26.0, *) {
            if Self.continuedEnabled { submitContinued() }
            (continued as? BGContinuedProcessingTask)?.updateTitle(
                String(format: tr("Downloading %@"), name), subtitle: source)
        }
        if isBackground { beginGrace() }
    }

    func progress(done: UInt64, total: UInt64) {
        guard #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask else { return }
        let totalUnits = Int64(clamping: max(total, 1))
        if task.progress.totalUnitCount != totalUnits { task.progress.totalUnitCount = totalUnits }
        task.progress.completedUnitCount = Int64(clamping: min(done, total))
    }

    func ended(name: String, outcome: Outcome, queueEmpty: Bool) {
        if isBackground {
            switch outcome {
            case .completed:
                notify(String(format: tr("%@ is ready to play"), name), body: String(format: tr("The %@ download finished."), source))
            case .failed(let reason):
                notify(String(format: tr("%@ download stopped"), name), body: reason)
            case .paused:
                break
            }
        }
        guard queueEmpty else { return }
        if case .completed = outcome { finishContinued(success: true) } else { finishContinued(success: false) }
        endGrace()
    }

    // MARK: iOS 26 continued processing

    @available(iOS 26.0, *)
    private func submitContinued() {
        guard continued == nil, !continuedPending, let identifier = taskIdentifier else { return }
        if !registered {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                MainActor.assumeIsolated { self?.run(task) }
            }
            guard ok else { log("register refused"); return }
            registered = true
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: String(format: tr("Downloading %@"), currentName),
                                                       subtitle: source)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedPending = true
            log("continued processing submitted")
        } catch {
            log("continued processing refused")
        }
    }

    @available(iOS 26.0, *)
    private func run(_ task: BGContinuedProcessingTask) {
        continuedPending = false
        continued = task
        task.progress.totalUnitCount = 1
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log("continued processing expired; pausing")
                self.pause()
                self.notify(tr("Download paused"), body: tr("Open iDeck to continue downloading."))
                self.finishContinued(success: false)
            }
        }
        if !isActive() { finishContinued(success: true) }
    }

    private func finishContinued(success: Bool) {
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        continued = nil
    }

    // MARK: Short grace period

    private func beginGrace() {
        guard graceTask == .invalid, continued == nil, isActive() else { return }
        graceTask = UIApplication.shared.beginBackgroundTask(withName: "iDeck \(source) download") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.continued == nil {
                    self.log("background time over; pausing")
                    self.pause()
                    self.notify(tr("Download paused"), body: tr("Open iDeck to continue downloading."))
                }
                self.endGrace()
            }
        }
    }

    private func endGrace() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }

    // MARK: Notifications

    private static var askedNotifications = false

    private func requestNotificationPermission() {
        guard !Self.askedNotifications, Self.notificationsEnabled else { return }
        Self.askedNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, body: String) {
        guard Self.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "ideck.download.\(UUID().uuidString)", content: content, trigger: nil))
    }
}
