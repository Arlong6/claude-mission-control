import SwiftUI
import AppKit

/// Settings sheet exposing the remote-access feature: toggle the server, show
/// the pairing QR, manage APNs credentials, list paired devices.
struct RemoteView: View {
    @EnvironmentObject var coordinator: RemoteCoordinator

    var body: some View {
        // Project RemoteSettings as an ObservedObject so the @AppStorage
        // projectedValues become valid SwiftUI Bindings.
        RemoteViewBody(coordinator: coordinator, settings: coordinator.settings)
    }
}

private struct RemoteViewBody: View {
    @ObservedObject var coordinator: RemoteCoordinator
    @ObservedObject var settings: RemoteSettings
    @State private var showingQR = false
    @State private var portText: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("Enable iOS remote access", isOn: Binding(
                    get: { coordinator.isRunning },
                    set: { _ in coordinator.toggle() }
                ))
                .help("Starts an HTTP server on this Mac that the MC Pocket iOS app can pair to.")

                LabeledContent("Port") {
                    TextField("Port", text: $portText)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            if let p = Int(portText), (1024..<65536).contains(p) {
                                settings.port = p
                                if coordinator.isRunning { coordinator.start() }
                            }
                        }
                        .onAppear { portText = String(settings.port) }
                }

                if let err = coordinator.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Server")
            }

            Section {
                Button {
                    showingQR = true
                } label: {
                    Label("Show pairing QR code", systemImage: "qrcode")
                }
                .disabled(!coordinator.isRunning)

                Button("Rotate shared secret", role: .destructive) {
                    settings.rotateSecret()
                }
                .help("Invalidates the QR + revokes every paired device. Pair them again.")
            } header: {
                Text("Pairing")
            } footer: {
                Text("MC Pocket scans the QR to connect. Hostname assumed: \(PairingPayload.defaultHostname()). On Tailscale, replace with the magic-DNS name in your hosts file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Team ID", text: $settings.apnsTeamId)
                TextField("Key ID", text: $settings.apnsKeyId)
                TextField("Bundle ID", text: $settings.apnsBundleId)
                Toggle("Use production APNs", isOn: $settings.apnsUseProduction)
                HStack {
                    TextField("Path to .p8", text: $settings.apnsP8Path)
                    Button("Browse…") { pickP8() }
                }
            } header: {
                Text("APNs (push notifications)")
            } footer: {
                Text("From your Apple Developer account → Keys. Without these, push doesn't fire — server still works, you just have to open the app to see updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !settings.devices.isEmpty {
                Section("Paired devices") {
                    ForEach(settings.devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.nickname).font(.headline)
                                Text(device.id.prefix(12) + "…")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                settings.removeDevice(token: device.id)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .sheet(isPresented: $showingQR) {
            QRSheet(payload: coordinator.currentPairingPayload())
        }
    }

    private func pickP8() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.message = "Select your APNs Authentication Key (.p8)"
        if panel.runModal() == .OK, let url = panel.url {
            settings.apnsP8Path = url.path
        }
    }
}

private struct QRSheet: View {
    let payload: PairingPayload.Payload
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan in MC Pocket")
                .font(.title2.bold())

            if let img = PairingPayload.qrImage(for: payload) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 280, height: 280)
            } else {
                Text("QR generation failed").foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Host", value: payload.host)
                LabeledContent("Port", value: String(payload.port))
                LabeledContent("Nickname", value: payload.nickname)
            }
            .font(.callout.monospaced())
            .padding()
            .background(Color(.windowBackgroundColor), in: .rect(cornerRadius: 8))

            Text(payload.url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 420)
    }
}

