// CarPlayBridge — the freshness path between Dart and the CarPlay scene.
//
// The App Group is the DATA path and always works, including when CarPlay
// launches the app with no phone window. This channel is the freshness path
// only: Dart pokes it after a snapshot rewrite, and it carries the two
// engine-dependent actions. With no engine the list still renders and those
// two buttons are simply absent — never present-but-broken.
//
// This file is compiled only on macOS/Xcode.

import Flutter
import Foundation

/// A completion that runs exactly once, whichever of the Dart reply and the
/// timeout below lands first. Main-queue only, so the flag needs no lock.
private final class OneShot<Value> {
    private var work: ((Value) -> Void)?

    init(_ work: @escaping (Value) -> Void) {
        self.work = work
    }

    func fire(_ value: Value) {
        guard let work else { return }
        self.work = nil
        work(value)
    }
}

extension Notification.Name {
    /// Posted when Dart becomes reachable, or stops being, so a connected
    /// scene can rebuild with or without the engine-dependent buttons.
    static let carPlayBridgeAvailabilityChanged = Notification.Name(
        "net.vogas.scheduling.carplay.bridgeAvailabilityChanged")
}

/// The implicit engine's messenger, captured once by `AppDelegate`. A CarPlay
/// scene can connect before the engine exists or long after it does, so both
/// channels resolve the messenger from here rather than from a view
/// controller that may have no window behind it.
enum FlutterMessengers {
    private(set) static var implicitEngine: FlutterBinaryMessenger?

    static func capture(_ messenger: FlutterBinaryMessenger) {
        implicitEngine = messenger
    }
}

final class CarPlayBridge {
    static let shared = CarPlayBridge()

    private init() {}

    private static let channelName = "net.vogas.scheduling/carplay"

    /// `main()` may not have set the Dart handler by the time the scene
    /// connects, and a ping that lands early is answered `notImplemented`.
    /// Without these retries one startup race hides both buttons for the
    /// whole drive.
    private static let pingRetryDelays: [TimeInterval] = [1, 3, 8]

    /// An awaited Firestore write only resolves on server ack, and no network
    /// is the ordinary condition in a car — so a reply may never come, and the
    /// caller's completion has to run anyway. Long enough that a slow-but-
    /// working write still reports success; short enough that a driver is not
    /// left looking at a button that did nothing.
    private static let writeTimeout: TimeInterval = 10

    /// Shorter, because the DETAIL SCREEN waits on this one: the row tap opens
    /// nothing until it answers. The read is normally served from the app's
    /// Firestore cache, so a slow answer means no engine rather than no signal.
    private static let lookupTimeout: TimeInterval = 3

    /// Whether Dart has ANSWERED. A registered channel is not enough — the
    /// engine can be up before `main()` has set its handler.
    private(set) var isConnected = false

    private var channel: FlutterMethodChannel?
    private var sceneIsConnected = false

    // MARK: - Registration

    func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        self.channel = channel
        guard sceneIsConnected else { return }
        ping(attempt: 0)
    }

    /// The scene's own belt and braces: the engine may have initialized
    /// before this scene connected, or never at all.
    func registerIfNeeded(messenger: FlutterBinaryMessenger?) {
        guard channel == nil, let messenger else { return }
        register(messenger: messenger)
    }

    // MARK: - Scene lifecycle

    func carPlaySceneDidConnect() {
        sceneIsConnected = true
        ping(attempt: 0)
    }

    func carPlaySceneDidDisconnect() {
        sceneIsConnected = false
    }

    // MARK: - Dart to Swift

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "snapshotChanged" else {
            result(FlutterMethodNotImplemented)
            return
        }
        onMain {
            NotificationCenter.default.post(
                name: .carPlaySnapshotChanged, object: nil)
        }
        // Dart writing to us proves it is up; ask again if a ping lost the race.
        if !isConnected { ping(attempt: 0) }
        result(nil)
    }

    // MARK: - Swift to Dart

    /// Asks Dart to refresh the snapshot now, and doubles as the reachability
    /// probe that gates the two engine-dependent buttons.
    private func ping(attempt: Int) {
        guard let channel, sceneIsConnected else { return }
        channel.invokeMethod("carPlayConnected", arguments: nil) { response in
            if Self.isUnhandled(response) {
                self.setConnected(false)
                self.retryPing(after: attempt)
                return
            }
            self.setConnected(true)
        }
    }

    private func retryPing(after attempt: Int) {
        guard attempt < Self.pingRetryDelays.count else { return }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.pingRetryDelays[attempt]
        ) {
            guard !self.isConnected else { return }
            self.ping(attempt: attempt + 1)
        }
    }

    /// `true` only when Dart committed the write. Anything else — no engine,
    /// a `FlutterError`, a rules rejection Dart caught, or no answer at all
    /// before `writeTimeout` — is a failure the scene turns into an alert.
    func setAppointmentStatus(
        id: String, status: String, completion: @escaping (Bool) -> Void
    ) {
        guard let channel, isConnected else {
            onMain { completion(false) }
            return
        }
        let once = OneShot(completion)
        channel.invokeMethod(
            "setAppointmentStatus", arguments: ["id": id, "status": status]
        ) { [weak self] response in
            if Self.isUnhandled(response) {
                Self.log("setAppointmentStatus", response)
                self?.setConnected(false)
                Self.onMainQueue { once.fire(false) }
                return
            }
            Self.onMainQueue { once.fire(response as? Bool == true) }
        }
        expire(once, with: false, after: Self.writeTimeout)
    }

    /// The finished `tel:` URI Dart built, so the stripping rule stays in one
    /// place. Nil means no number on file, no engine, or no answer inside
    /// `lookupTimeout` — all the same answer to the caller: no Call button.
    /// The caller pushes the detail from here, so a reply that never comes
    /// would otherwise mean a row tap that opens nothing, ever.
    func dialableNumber(for id: String, completion: @escaping (URL?) -> Void) {
        guard let channel, isConnected else {
            onMain { completion(nil) }
            return
        }
        let once = OneShot(completion)
        channel.invokeMethod("dialableNumberFor", arguments: ["id": id]) {
            [weak self] response in
            if Self.isUnhandled(response) {
                Self.log("dialableNumberFor", response)
                self?.setConnected(false)
                Self.onMainQueue { once.fire(nil) }
                return
            }
            let uri = (response as? String).flatMap(URL.init(string:))
            Self.onMainQueue { once.fire(uri) }
        }
        expire(once, with: nil, after: Self.lookupTimeout)
    }

    /// The other half of every `OneShot`: the answer the caller gets when Dart
    /// never replies. Fires on the main queue, where `OneShot` is read.
    private func expire<Value>(
        _ once: OneShot<Value>, with value: Value, after timeout: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            once.fire(value)
        }
    }

    // MARK: - Plumbing

    private func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        onMain {
            NotificationCenter.default.post(
                name: .carPlayBridgeAvailabilityChanged, object: nil)
        }
    }

    /// A `FlutterError` or an unregistered handler. Either way Dart did not
    /// answer, and nothing here may throw its way out to a crash.
    private static func isUnhandled(_ response: Any?) -> Bool {
        if response is FlutterError { return true }
        if let object = response as? NSObject,
           object === FlutterMethodNotImplemented {
            return true
        }
        return false
    }

    private static func log(_ method: String, _ response: Any?) {
        guard let error = response as? FlutterError else {
            NSLog("CarPlay \(method): no Dart handler")
            return
        }
        NSLog("CarPlay \(method) failed: \(error.code)")
    }

    private func onMain(_ work: @escaping () -> Void) {
        Self.onMainQueue(work)
    }

    /// Static so a reply arriving after this singleton is somehow gone still
    /// reaches the caller's completion.
    private static func onMainQueue(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
