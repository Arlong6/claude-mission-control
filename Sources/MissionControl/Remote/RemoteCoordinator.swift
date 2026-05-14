import Foundation
import SwiftUI

/// Lifecycle owner: starts/stops the HTTP server, wires routes against the
/// live ProjectStore, owns the APNs pusher, and observes project changes to
/// push notifications to paired devices.
@MainActor
final class RemoteCoordinator: ObservableObject {
    let settings: RemoteSettings
    private let store: ProjectStore

    private var server: HTTPServer?
    private var routes: APIRoutes?
    private var pusher: APNsPusher?

    @Published var lastError: String?
    @Published var isRunning: Bool = false

    private var observeTask: Task<Void, Never>?
    private var lastStatusSnapshot: [String: String] = [:]  // projectId -> status

    init(settings: RemoteSettings, store: ProjectStore) {
        self.settings = settings
        self.store = store
        if settings.enabled { start() }
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        stop()
        let s = HTTPServer()
        do {
            try s.start(port: UInt16(settings.port))
            self.server = s
            self.routes = APIRoutes(server: s, store: store, settings: settings)
            self.isRunning = true
            self.lastError = nil
            settings.enabled = true
            wireAPNs()
            observeProjects()
        } catch {
            self.lastError = "Server failed to start: \(error.localizedDescription)"
            self.isRunning = false
        }
    }

    func stop() {
        observeTask?.cancel()
        observeTask = nil
        server?.stop()
        server = nil
        routes = nil
        pusher = nil
        isRunning = false
        settings.enabled = false
    }

    private func wireAPNs() {
        guard !settings.apnsTeamId.isEmpty,
              !settings.apnsKeyId.isEmpty,
              !settings.apnsP8Path.isEmpty
        else { return }
        pusher = APNsPusher(config: .init(
            teamId: settings.apnsTeamId,
            keyId: settings.apnsKeyId,
            bundleId: settings.apnsBundleId,
            p8Path: settings.apnsP8Path,
            useProduction: settings.apnsUseProduction
        ))
    }

    // MARK: - Push fan-out

    /// Watches the @Published projects array on the store and pushes whenever
    /// any project transitions into a notable state (error / waitingForInput).
    private func observeProjects() {
        observeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.maybePush()
            }
        }
    }

    private func maybePush() async {
        guard let pusher else { return }
        let snapshot = computeStatusSnapshot()
        defer { lastStatusSnapshot = snapshot }

        let rules = settings.rules
        for (id, status) in snapshot {
            let prev = lastStatusSnapshot[id]
            guard prev != status else { continue }
            guard status == "error" || status == "waitingForInput" else { continue }
            guard let project = store.projects.first(where: { $0.id == id }) else { continue }

            let title = project.shortName
            let body = status == "error" ? "errored" : "waiting for your input"

            // Honour iOS-side push rules: quiet hours, per-project mute, keyword overrides.
            guard rules.shouldPush(projectId: id, kind: status, bodyPreview: body) else { continue }

            let payload = APNsPusher.Payload(
                aps: .init(
                    alert: .init(title: title, body: body),
                    sound: "default",
                    mutableContent: 1,
                    interruptionLevel: "time-sensitive"
                ),
                projectId: project.id,
                sessionId: project.sessions.first?.id,
                kind: status
            )
            for device in settings.devices {
                do {
                    try await pusher.push(to: device.id, payload: payload)
                } catch {
                    self.lastError = "Push to \(device.nickname) failed: \(error)"
                }
            }
        }
    }

    private func computeStatusSnapshot() -> [String: String] {
        Dictionary(uniqueKeysWithValues: store.projects.map { p -> (String, String) in
            let status: String
            if p.meta.hasError { status = "error" }
            else if Date().timeIntervalSince(p.lastActivity) < 60 { status = "running" }
            else if Date().timeIntervalSince(p.lastActivity) < 3600 { status = "waitingForInput" }
            else { status = "idle" }
            return (p.id, status)
        })
    }

    // MARK: - Pairing payload for the QR view

    func currentPairingPayload() -> PairingPayload.Payload {
        PairingPayload.Payload(
            host: PairingPayload.defaultHostname(),
            port: UInt16(settings.port),
            secret: settings.secret,
            nickname: Host.current().localizedName ?? "Mac"
        )
    }
}
