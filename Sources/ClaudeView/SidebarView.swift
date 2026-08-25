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
                        LiveSessionRow(
                            session: live.session,
                            usage: model.contextUsage(for: live.ref.url)
                        )
                        .tag(live.ref)
                        ForEach(model.sidebarAgents(for: live.ref)) { agent in
                            AgentTreeRow(agent: agent)
                        }
                    }
                }
            }

            ForEach(model.historyProjects) { project in
                Section(AppModel.displayName(forSlug: project.slug)) {
                    ForEach(project.transcripts) { transcript in
                        HistorySessionRow(
                            transcript: transcript,
                            title: model.title(for: transcript),
                            usage: model.contextUsage(for: transcript.url)
                        )
                        .tag(
                            SessionRef(
                                projectSlug: project.slug,
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
    /// Context size of the last turn. Live is no guarantee of warm — a
    /// TUI left idle past the TTL reprocesses everything on the next
    /// message — so the count wears the same warmth color as history.
    let usage: ContextUsage?

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
                    cwdLine(cwd)
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
        .help(usage.map { warmthHint($0, verb: "next turn") } ?? "")
    }

    private func cwdLine(_ cwd: String) -> Text {
        let base = Text((cwd as NSString).abbreviatingWithTildeInPath)
        guard let usage else { return base }
        return base + warmTokenText(" · " + tokenLabel(usage.contextTokens), usage: usage)
    }
}

struct HistorySessionRow: View {
    let transcript: TranscriptFile
    let title: String?
    let usage: ContextUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? String(transcript.sessionId.prefix(8)))
                .lineLimit(1)
            subtitle
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(usage.map { warmthHint($0, verb: "resume") } ?? "")
    }

    /// "2 weeks ago · 2.2 MB · 181k tok" — the token run turns orange
    /// while the prompt cache is presumed warm.
    private var subtitle: Text {
        let base = Text(
            transcript.modifiedAt.formatted(.relative(presentation: .named))
                + " · " + transcript.size.formatted(.byteCount(style: .file)))
        guard let usage else { return base }
        return base
            + warmTokenText(" · " + tokenLabel(usage.contextTokens) + " tok", usage: usage)
    }
}

/// "412", "263k", "1.3M" — sidebar-density token counts.
private func tokenLabel(_ count: Int64) -> String {
    switch count {
    case ..<1_000: "\(count)"
    case ..<1_000_000: "\((count + 500) / 1_000)k"
    default: String(format: "%.1fM", Double(count) / 1_000_000)
    }
}

/// A token-count run that turns orange while the cache is presumed
/// warm; time-based, so each heartbeat re-render lets it cool off.
private func warmTokenText(_ label: String, usage: ContextUsage) -> Text {
    guard usage.warmUntil > Date() else { return Text(label) }
    return Text(label).foregroundStyle(.orange)
}

/// Row tooltip; `verb` names the act the cost applies to — "resume"
/// for history rows, "next turn" for live ones.
private func warmthHint(_ usage: ContextUsage, verb: String) -> String {
    let tokens = tokenLabel(usage.contextTokens)
    guard usage.warmUntil > Date() else {
        return "Cache cold — \(verb) reprocesses ~\(tokens) tokens uncached"
    }
    let minutes = max(1, Int(usage.warmUntil.timeIntervalSinceNow / 60))
    return "Cache warm — \(verb) reuses ~\(tokens) tokens (expires in ~\(minutes)m)"
}

/// One node of the agent tree. Agents with children render as a
/// disclosure, collapsed by default — code-review shows; its dozen
/// Explore finders wait behind the chevron.
struct AgentTreeRow: View {
    let agent: ActiveSubagent

    @State private var isExpanded = false

    var body: some View {
        if agent.children.isEmpty {
            ActiveSubagentRow(agent: agent, state: agent.state)
                .tag(agent.ref)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(agent.children) { child in
                    AgentTreeRow(agent: child)
                }
            } label: {
                ActiveSubagentRow(agent: agent, state: agent.aggregateState)
                    .tag(agent.ref)
            }
        }
    }
}

struct ActiveSubagentRow: View {
    let agent: ActiveSubagent
    let state: ActiveSubagent.State

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
            switch state {
            case .processing:
                ProgressView()
                    .controlSize(.mini)
            case .idle:
                Circle().fill(Color.orange).frame(width: 7, height: 7)
            case .inactive:
                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            case .completed:
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(state <= .inactive ? 0.55 : 1)
        .padding(.vertical, 1)
    }
}
