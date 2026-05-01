import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var confirmAction: ConfirmAction?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("PROJECTS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                Text("\(store.projects.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            List(selection: Binding(
                get: { store.selectedID },
                set: { store.selectedID = $0 }
            )) {
                ForEach(store.projects) { p in
                    ProjectRow(project: p) { action in
                        switch action {
                        case .hide:
                            store.hide(p.id)
                        case .clear:
                            confirmAction = .init(kind: .clear, project: p)
                        case .hardDelete:
                            confirmAction = .init(kind: .hardDelete, project: p)
                        }
                    }
                    .tag(p.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.regularMaterial)
        .alert(item: $confirmAction) { ca in
            switch ca.kind {
            case .clear:
                return Alert(
                    title: Text("Clear all sessions for \(ca.project.shortName)?"),
                    message: Text("Deletes only the .jsonl files in ~/.claude/projects/\(ca.project.id)/. Code untouched."),
                    primaryButton: .destructive(Text("Clear")) {
                        try? store.clearSession(ca.project.id)
                    },
                    secondaryButton: .cancel())
            case .hardDelete:
                return Alert(
                    title: Text("Hard delete Claude data for \(ca.project.shortName)?"),
                    message: Text("Removes the entire ~/.claude/projects/\(ca.project.id)/ folder (memory + sessions). Your code at \(ca.project.originalPath) is NOT touched."),
                    primaryButton: .destructive(Text("Delete")) {
                        try? store.hardDelete(ca.project.id)
                    },
                    secondaryButton: .cancel())
            }
        }
    }
}

struct ConfirmAction: Identifiable {
    enum Kind { case clear, hardDelete }
    let id = UUID()
    let kind: Kind
    let project: Project
}

struct ProjectRow: View {
    let project: Project
    let onAction: (RowAction) -> Void
    @State private var hovering = false

    enum RowAction { case hide, clear, hardDelete }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [project.accentColor.opacity(0.95), project.accentColor.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 9, height: 9)
                .shadow(color: project.accentColor.opacity(0.5), radius: 2, x: 0, y: 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(project.shortName)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .lineLimit(1)
                    if project.meta.hasError {
                        Circle().fill(.red).frame(width: 6, height: 6)
                    }
                }
                Text(project.relativeActivityString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            badges
            if hovering {
                Menu {
                    Button("Hide") { onAction(.hide) }
                    Button("Clear sessions…") { onAction(.clear) }
                    Divider()
                    Button("Hard delete…", role: .destructive) { onAction(.hardDelete) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Hide") { onAction(.hide) }
            Button("Clear sessions…") { onAction(.clear) }
            Divider()
            Button("Hard delete…", role: .destructive) { onAction(.hardDelete) }
        }
    }

    @ViewBuilder
    var badges: some View {
        HStack(spacing: 4) {
            if project.meta.gitDirty > 0 {
                badge("git \(project.meta.gitDirty)", color: .orange)
            }
            if project.meta.todoOpen > 0 {
                badge("☐\(project.meta.todoOpen)", color: .blue)
            }
        }
    }

    func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
