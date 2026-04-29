import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var confirmAction: ConfirmAction?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                Text("\(store.projects.count)").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

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
        }
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
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(project.shortName)
                        .font(.system(.body, design: .rounded))
                        .lineLimit(1)
                    if project.meta.hasError {
                        Circle().fill(.red).frame(width: 7, height: 7)
                    }
                }
                Text(project.relativeActivityString)
                    .font(.caption2)
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
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(.vertical, 2)
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
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
