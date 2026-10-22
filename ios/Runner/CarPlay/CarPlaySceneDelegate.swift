// CarPlaySceneDelegate — the CarPlay scene's lifecycle, and every tap.
//
// The tab bar plus one detail push sits exactly at the iOS 18 depth cap of 2,
// so nothing here pushes twice; a rebuild that would land under a pushed
// detail or a presented alert is deferred instead.
//
// The root is installed ONCE. A rebuild updates the two list templates in
// place, because installing a new root installs a new tab bar and the driver
// loses the tab they were reading — every 60 s, on the re-rank timer.
//
// Every callback here arrives on the main queue, and every closure a template
// retains captures this delegate weakly — the rows outlive the tap that built
// them.
//
// This file is compiled only on macOS/Xcode.

import CarPlay
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private weak var templateScene: CPTemplateApplicationScene?
    private var todayTab: CPListTemplate?
    private var weekTab: CPListTemplate?
    private var detail: CPInformationTemplate?
    private var presentedAlert: CPAlertTemplate?
    private var bridgeObserver: NSObjectProtocol?
    private var isSceneActive = false
    private var rebuildIsPending = false
    private var sceneGeneration = 0
    private var selectionGeneration = 0
    private var snapshotOwner: String?
    private var snapshotEpoch: String?
    /// A `CPTextButton` has no disabled state, so a driver can tap Start or
    /// Mark complete again while the first write is still in flight — and
    /// offline they all commit at once on reconnect. The bridge answers every
    /// call exactly once, so this always clears.
    private var statusWriteIsInFlight = false

    private var store: CarPlayScheduleStore { .shared }

    // MARK: - Scene lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        sceneGeneration += 1
        selectionGeneration += 1
        templateScene = templateApplicationScene
        self.interfaceController = interfaceController
        interfaceController.delegate = self

        // onChange first: activate() reloads and fires it.
        store.onChange = { [weak self] in self?.rebuild() }
        store.activate()
        snapshotOwner = store.snapshot?.ownerUid
        snapshotEpoch = store.snapshot?.sessionEpoch

        bridgeObserver = NotificationCenter.default.addObserver(
            forName: .carPlayBridgeAvailabilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.rebuild() }

        CarPlayBridge.shared.registerIfNeeded(
            messenger: FlutterMessengers.implicitEngine)
        CarPlayBridge.shared.carPlaySceneDidConnect()

        isSceneActive = true
        installRoot(on: interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        isSceneActive = false
        sceneGeneration += 1
        selectionGeneration += 1
        rebuildIsPending = false
        statusWriteIsInFlight = false
        store.deactivate()
        CarPlayBridge.shared.carPlaySceneDidDisconnect()
        if let bridgeObserver {
            NotificationCenter.default.removeObserver(bridgeObserver)
        }
        bridgeObserver = nil
        todayTab = nil
        weekTab = nil
        detail = nil
        presentedAlert = nil
        interfaceController.delegate = nil
        self.interfaceController = nil
        templateScene = nil
    }

    // MARK: - Templates

    /// The one `setRootTemplate` of the scene's life. The tab bar owns its two
    /// children, so they are read back off it rather than built a second time.
    private func installRoot(on controller: CPInterfaceController) {
        let root = CarPlayTemplateBuilder.rootTemplate(
            snapshot: store.snapshot,
            now: Date(),
            presentation: presentation(),
            actions: actions())
        // Week is taken by POSITION, never `last`: with one tab that is the
        // same template as Today, and refreshing Week would overwrite it.
        let tabs = root.templates.compactMap { $0 as? CPListTemplate }
        todayTab = tabs.first
        weekTab = tabs.count > 1 ? tabs[1] : nil
        controller.setRootTemplate(root, animated: false, completion: nil)
    }

    /// Read fresh every time: `contentStyle` follows the car's day/night
    /// switch, and the bridge can connect long after the scene did.
    private func presentation() -> CarPlayPresentation {
        CarPlayPresentation(
            style: templateScene?.contentStyle ?? .unspecified,
            // Present only on an admin snapshot whose name resolved; nil rings
            // nothing, which is the safe direction.
            viewerName: store.snapshot?.viewer,
            bridgeConnected: CarPlayBridge.shared.isConnected)
    }

    private func actions() -> CarPlayActions {
        let generation = sceneGeneration
        return CarPlayActions(
            select: { [weak self] appointment in
                guard self?.sceneGeneration == generation else { return }
                self?.showDetail(for: appointment)
            },
            directions: { [weak self] appointment in
                guard self?.sceneGeneration == generation else { return }
                self?.openDirections(to: appointment)
            },
            setStatus: { [weak self] appointment, status in
                guard self?.sceneGeneration == generation else { return }
                self?.writeStatus(status, for: appointment)
            },
            call: { [weak self] url in
                guard self?.sceneGeneration == generation else { return }
                self?.open(url)
            },
            dismissAlert: { [weak self] in
                guard self?.sceneGeneration == generation else { return }
                self?.dismissAlert()
            })
    }

    private func rebuild() {
        guard isSceneActive, todayTab != nil || weekTab != nil else { return }
        if store.snapshot == nil || snapshotOwner != store.snapshot?.ownerUid ||
            snapshotEpoch != store.snapshot?.sessionEpoch {
            snapshotOwner = store.snapshot?.ownerUid
            snapshotEpoch = store.snapshot?.sessionEpoch
            sceneGeneration += 1
            selectionGeneration += 1
            statusWriteIsInFlight = false
            detail = nil
            let hadAlert = presentedAlert != nil
            presentedAlert = nil
            if hadAlert {
                interfaceController?.dismissTemplate(animated: false, completion: nil)
            }
            interfaceController?.popToRootTemplate(animated: false, completion: nil)
        }
        // A rebuild under a pushed detail pops the driver out of it, and one
        // under an alert races the answer they are reading.
        guard detail == nil, presentedAlert == nil else {
            rebuildIsPending = true
            return
        }
        rebuildIsPending = false
        let snapshot = store.snapshot
        let now = Date()
        let current = presentation()
        let handlers = actions()
        if let todayTab {
            CarPlayTemplateBuilder.refreshToday(
                todayTab, snapshot: snapshot, now: now,
                presentation: current, actions: handlers)
        }
        if let weekTab {
            CarPlayTemplateBuilder.refreshWeek(
                weekTab, snapshot: snapshot, now: now,
                presentation: current, actions: handlers)
        }
    }

    private func rebuildIfPending() {
        guard rebuildIsPending else { return }
        rebuild()
    }

    // MARK: - Detail

    /// The number is fetched ONCE, before the push, so the same answer
    /// decides whether Call renders and what it opens.
    private func showDetail(for appointment: SnapshotAppointment) {
        guard isSceneActive else { return }
        selectionGeneration += 1
        let selection = selectionGeneration
        let generation = sceneGeneration
        guard let current = latestAppointment(id: appointment.id) else { return }
        guard CarPlayBridge.shared.isConnected else {
            pushDetail(for: current, dialableURI: nil)
            return
        }
        CarPlayBridge.shared.dialableNumber(for: appointment.id) {
            [weak self] uri in
            guard let self, self.isSceneActive,
                  self.sceneGeneration == generation,
                  self.selectionGeneration == selection,
                  let latest = self.latestAppointment(id: appointment.id) else { return }
            self.pushDetail(for: latest, dialableURI: uri)
        }
    }

    private func latestAppointment(id: String) -> SnapshotAppointment? {
        let matches = store.snapshot?.days.flatMap(\.appointments).filter { $0.id == id } ?? []
        return matches.first { Calendar.current.isDate($0.start, inSameDayAs: Date()) }
            ?? matches.first { $0.end > Date() } ?? matches.last
    }

    private func pushDetail(
        for appointment: SnapshotAppointment, dialableURI: URL?
    ) {
        guard isSceneActive, let interfaceController, detail == nil else { return }
        let template = CarPlayTemplateBuilder.detailTemplate(
            for: appointment,
            snapshot: store.snapshot,
            now: Date(),
            presentation: presentation(),
            dialableURI: dialableURI,
            actions: actions())
        detail = template
        let generation = sceneGeneration
        let selection = selectionGeneration
        // pushTemplate FAILS at the depth cap rather than throwing back here,
        // so the completion is the only place that failure is visible.
        interfaceController.pushTemplate(template, animated: true) {
            [weak self] pushed, _ in
            guard let self, self.sceneGeneration == generation,
                  self.selectionGeneration == selection, self.detail === template,
                  !pushed else { return }
            self.detail = nil
            self.present(self.failureAlert(CarPlayStrings.couldNotOpenJob))
        }
    }

    // MARK: - Actions

    private func writeStatus(_ status: String, for appointment: SnapshotAppointment) {
        guard isSceneActive, store.snapshot != nil, !statusWriteIsInFlight else { return }
        let generation = sceneGeneration
        let selection = selectionGeneration
        statusWriteIsInFlight = true
        CarPlayBridge.shared.setAppointmentStatus(
            id: appointment.id, status: status
        ) { [weak self] written in
            guard let self, self.isSceneActive, self.sceneGeneration == generation,
                  self.selectionGeneration == selection else { return }
            self.statusWriteIsInFlight = false
            guard written else {
                self.present(self.failureAlert(CarPlayStrings.couldNotUpdateJob))
                return
            }
            self.popToRoot()
        }
    }

    private func openDirections(to appointment: SnapshotAppointment) {
        guard let url = Self.directionsURL(for: appointment) else { return }
        dismissAlert()
        open(url)
    }

    private func open(_ url: URL) {
        guard let templateScene else { return }
        templateScene.open(url, options: nil, completionHandler: nil)
    }

    /// A query rather than a pin: appointments store an address string with no
    /// coordinates.
    private static func directionsURL(for appointment: SnapshotAppointment) -> URL? {
        let address = appointment.address
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "daddr", value: address),
            URLQueryItem(name: "dirflg", value: "d"),
        ]
        return components.url
    }

    // MARK: - Modal templates

    /// One modal at a time: a second present would fail and leave the alert
    /// on screen untracked, with a rebuild free to run underneath it.
    private func present(_ alert: CPAlertTemplate) {
        guard isSceneActive, let interfaceController, presentedAlert == nil
        else { return }
        presentedAlert = alert
        let generation = sceneGeneration
        interfaceController.presentTemplate(alert, animated: true) {
            [weak self] presented, _ in
            guard let self, self.sceneGeneration == generation,
                  self.presentedAlert === alert, !presented else { return }
            self.presentedAlert = nil
            self.rebuildIfPending()
        }
    }

    private func dismissAlert() {
        guard let interfaceController, presentedAlert != nil else { return }
        presentedAlert = nil
        interfaceController.dismissTemplate(animated: true) { [weak self] _, _ in
            self?.rebuildIfPending()
        }
    }

    private func popToRoot() {
        selectionGeneration += 1
        detail = nil
        guard let interfaceController else { return }
        interfaceController.popToRootTemplate(animated: true) {
            [weak self] _, _ in
            self?.rebuild()
        }
    }

    /// A Dart failure is a "couldn't do that" the driver can dismiss, never a
    /// crash and never a silent no-op.
    private func failureAlert(_ message: String) -> CPAlertTemplate {
        CPAlertTemplate(
            titleVariants: [message, CarPlayStrings.couldNotDoThatShort],
            actions: [
                CPAlertAction(
                    title: CarPlayStrings.okAction, style: .default
                ) { [weak self] _ in self?.dismissAlert() },
            ])
    }
}

// MARK: - CPInterfaceControllerDelegate

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    /// The driver's own back tap is the other way out of the detail, and a
    /// rebuild has been waiting for it.
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        if aTemplate === detail { detail = nil }
        if aTemplate === presentedAlert { presentedAlert = nil }
        rebuildIfPending()
    }
}
