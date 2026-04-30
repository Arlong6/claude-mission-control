import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            Group {
                if let project = store.selected {
                    ChatView(project: project, vm: store.chatViewModel(for: project))
                        .id(project.id)
                } else {
                    EmptyChatPlaceholder()
                }
            }
            .frame(minWidth: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet().environmentObject(settings)
        }
    }
}

struct EmptyChatPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No project selected")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Pick one from the sidebar to start chatting")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2).bold()
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360, height: 200)
    }
}
