import ClaudeViewCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Live") {
                if model.liveRefs.isEmpty {
                    Text("No running sessions")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(model.liveRefs, id: \.ref) { live in
                        LiveSessionRow(session: live.session)
                            .tag(live.ref)
                        ForEach(model.sidebarAgents(for: live.ref)) { agent in
                            ActiveSubagentRow(agent: agent)
                                .tag(agent.ref)
                        }
                    }
                }
            }

            ForEach(model.historyProjects, id: \.project.id) { group in
                Section(AppModel.displayName(forSlug: group.project.slug)) {
                    ForEach(group.transcripts.prefix(15)) { transcript in
                        HistorySessionRow(
                            transcript: transcript,
                            title: model.title(for: transcript)
                        )
                        .tag(
                            SessionRef(
                                projectSlug: group.project.slug,
                                sessionId: transcript.sessionId,
                                url: transcript.url))
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        .toolbar {
            ToolbarItem {
                Button {
                    model.agentFilterRunningOnly.toggle()
                } label: {
                    Label(
                        "Filter agents",
                        systemImage: model.agentFilterRunningOnly
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                }
                .help(
                    model.agentFilterRunningOnly
                        ? "Showing active agents only — click for all"
                        : "Showing all agents — click for active only")
            }
        }
    }
}

struct LiveSessionRow: View {
    let session: RegistrySession

    private var isBusy: Bool { session.status == "busy" }
    private var isIdle: Bool { session.status == "idle" || session.status == nil }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isBusy ? Color.orange : isIdle ? Color.green : Color.yellow)
                .frame(width: 8, height: 8)
                .accessibilityLabel(session.status ?? "idle")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? session.sessionId?.prefix(8).description ?? "session")
                    .lineLimit(1)
                if let cwd = session.cwd {
                    Text((cwd as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if !isIdle, let status = session.status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct HistorySessionRow: View {
    let transcript: TranscriptFile
    let title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? String(transcript.sessionId.prefix(8)))
                .lineLimit(1)
            Text(
                transcript.modifiedAt.formatted(.relative(presentation: .named))
                    + " · " + transcript.size.formatted(.byteCount(style: .file))
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ActiveSubagentRow: View {
    let agent: ActiveSubagent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let started = agent.startedAt {
                        Text(started, format: .dateTime.hour().minute())
                    }
                    if let detail = agent.detail {
                        Text("· " + detail)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            switch agent.state {
            case .processing:
                ProgressView()
                    .controlSize(.mini)
            case .idle:
                Circle().fill(Color.orange).frame(width: 7, height: 7)
            case .inactive:
                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            }
        }
        .opacity(agent.state == .inactive ? 0.55 : 1)
        .padding(.leading, 16 + CGFloat(agent.depth) * 14)
        .padding(.vertical, 1)
    }
}
