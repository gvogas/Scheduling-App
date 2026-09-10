// CarPlayScheduleStore — the CarPlay scene's read model.
//
// It reads the same App Group snapshot Siri answers from, so the car renders
// with no Flutter engine, no Firestore and no network. The method channel is
// the freshness path only: a ping re-reads what Dart just wrote.
//
// Everything here runs on the main queue — CarPlay callbacks must.
//
// This file is compiled only on macOS/Xcode.

import UIKit

extension Notification.Name {
    /// Posted in-process by CarPlayBridge when Dart rewrites the snapshot.
    static let carPlaySnapshotChanged = Notification.Name(
        "net.vogas.scheduling.carplay.snapshotChanged")
}

/// How often the visible Today template is re-ranked while connected. Two of
/// its header subtitles are wall-clock text, and the Now/Next split moves with
/// the clock even when nothing is written.
private let rerankInterval: TimeInterval = 60

final class CarPlayScheduleStore {
    static let shared = CarPlayScheduleStore()

    private init() {}

    /// Called on the main queue whenever the visible template should be
    /// rebuilt — a fresh snapshot, or the 60 s re-rank. The scene delegate
    /// owns this and MUST capture itself weakly.
    var onChange: (() -> Void)?

    /// The last successfully decoded snapshot. Nil means signed out, or the
    /// app has never run.
    private(set) var snapshot: ScheduleSnapshot?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Scene lifecycle

    /// Connect: read fresh, watch for changes, start re-ranking.
    func activate() {
        stopObserving()
        reload()
        observe(.carPlaySnapshotChanged)
        observe(UIApplication.didBecomeActiveNotification)
        startTicking()
    }

    /// Disconnect: nothing may outlive the scene — the decoded snapshot least
    /// of all, since it holds client names and addresses.
    func deactivate() {
        stopTicking()
        stopObserving()
        onChange = nil
        snapshot = nil
        CarPlayImages.clearCache()
    }

    /// Re-reads the App Group. The decode is cached — this is the only thing
    /// that spends one, and it notifies only when the content actually moved.
    func reload() {
        let fresh = ScheduleSnapshot.load()
        let changed = fresh?.generatedAt != snapshot?.generatedAt
            || fresh?.days != snapshot?.days
            || fresh?.role != snapshot?.role
        snapshot = fresh
        guard changed else { return }
        notify()
    }

    // MARK: - Re-rank timer

    private func startTicking() {
        stopTicking()
        let timer = Timer(
            timeInterval: rerankInterval, repeats: true
        ) { [weak self] _ in
            self?.notify()
        }
        // .common so the tick survives a scrolling list on the head unit.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func observe(_ name: Notification.Name) {
        let token = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        observers.append(token)
    }

    private func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func notify() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.notify() }
            return
        }
        onChange?()
    }
}
