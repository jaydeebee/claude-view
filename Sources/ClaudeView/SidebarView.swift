import AppKit
import ClaudeViewCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    /// The clock, as far as this view is concerned.
    ///
    /// Warmth colour and "3 minutes ago" are read off the current time,
    /// and nothing else about a quiet session changes — so a sidebar left
    /// alone kept drawing a cache as warm long after it expired, which is
    /// exactly when you come back and look at it. Once a minute is fine
    /// for both: the colour is a hint, not a countdown.
    @State private var now = Date()

    var body: some View {
        List(selection: $model.selection) {
            Section("Live") {
                if !model.hasScanned {
                    // Before the first scan lands there is nothing to
                    // report — saying "none" here asserts a fact not yet
                    // in evidence, and on a machine with sessions running
                    // it is briefly a lie.
                    Text("Looking for sessions…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else if model.liveRefs.isEmpty {
                    Text("No running sessions")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(model.liveRefs, id: \.ref) { live in
                        LiveSessionRow(
                            session: live.session,
                            title: model.title(for: live.ref.url),
                            usage: model.contextUsage(for: live.ref.url),
                            now: now
                        )
                        .tag(live.ref)
                        .contextMenu {
                            SessionCopyMenu(
                                sessionId: live.ref.sessionId,
                                directory: live.session.cwd)
                        }
                        ForEach(model.sidebarAgents(for: live.ref)) { agent in
                            AgentTreeRow(agent: agent)
                        }
                    }
                }
            }

            ForEach(model.historyProjects) { project in
                Section {
                    ForEach(project.transcripts) { transcript in
                        HistorySessionRow(
                            transcript: transcript,
                            title: model.title(for: transcript.url),
                            usage: model.contextUsage(for: transcript.url),
                            now: now
                        )
                        .tag(
                            SessionRef(
                                projectSlug: project.slug,
                                sessionId: transcript.sessionId,
                                url: transcript.url))
                        .contextMenu {
                            SessionCopyMenu(
                                sessionId: transcript.sessionId,
                                directory: model.path(forSlug: project.slug))
                        }
                    }
                } header: {
                    ProjectHeader(
                        slug: project.slug, path: model.path(forSlug: project.slug))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
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
    /// What the session is about, from its own transcript — the same
    /// ai-title the history rows show. The registry's derived name
    /// ("claude-view-8d") says where it is running and which session it
    /// is, which the row already says twice: once in the path below and
    /// once by being selectable. It stays as the fallback for a session
    /// too young to have earned a title, and in the tooltip.
    let title: String?
    /// Context size of the last turn. Live is no guarantee of warm — a
    /// TUI left idle past the TTL reprocesses everything on the next
    /// message — so the count wears the same warmth color as history.
    let usage: ContextUsage?
    /// Passed in rather than read here, so the row redraws when the
    /// sidebar's clock ticks.
    let now: Date

    private var isBusy: Bool { session.status == "busy" }
    private var isIdle: Bool { session.status == "idle" || session.status == nil }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isBusy ? Color.orange : isIdle ? Color.green : Color.yellow)
                .frame(width: 8, height: 8)
                .accessibilityLabel(session.status ?? "idle")
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    title ?? session.name
                        ?? session.sessionId?.prefix(8).description ?? "session"
                )
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
                // Whatever the registry says, in whatever length: a status
                // this build has never met is still just a word in a
                // narrow column, and unclamped it pushes the row wider
                // than the sidebar.
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 72, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .help(helpText)
    }

    /// The derived name still has a job — it is what the session calls
    /// itself in a terminal — so it lives here once the title takes the
    /// row.
    private var helpText: String {
        let warmth = usage.map { warmthHint($0, verb: "next turn", now: now) }
        let name = title == nil ? nil : session.name
        return [name, warmth].compactMap { $0 }.joined(separator: "\n")
    }

    private func cwdLine(_ cwd: String) -> Text {
        let base = Text((cwd as NSString).abbreviatingWithTildeInPath)
        guard let usage else { return base }
        return base
            + warmTokenText(" · " + tokenLabel(usage.contextTokens), usage: usage, now: now)
    }
}

/// Right-click actions on a session row. The id is what `claude
/// --resume` takes, and copying it out of this window is the whole
/// reason anyone asked to see it — so the command comes ready-made
/// beside the bare id rather than making the reader assemble it.
struct SessionCopyMenu: View {
    let sessionId: String
    /// Where the session ran, so the resume command can carry the `cd`.
    let directory: String?

    var body: some View {
        Button("Copy Session ID") { copyToPasteboard(sessionId) }
        Button("Copy Resume Command") {
            copyToPasteboard(
                ResumeCommand.text(sessionId: sessionId, directory: directory))
        }
    }
}

/// A history group's heading: the directory its sessions ran in, shown
/// the way the Live rows above already show theirs. The slug-derived
/// name is the fallback for a project whose transcripts never said —
/// it reads worse and can be ambiguous, but it is never wrong about
/// which directory on disk the sessions were filed under.
struct ProjectHeader: View {
    let slug: String
    let path: String?

    var body: some View {
        Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath }
            ?? AppModel.displayName(forSlug: slug))
            .lineLimit(1)
            .truncationMode(.head)
            .help(path ?? slug)
    }
}

private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

struct HistorySessionRow: View {
    let transcript: TranscriptFile
    let title: String?
    let usage: ContextUsage?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? String(transcript.sessionId.prefix(8)))
                .lineLimit(1)
            subtitle
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(usage.map { warmthHint($0, verb: "resume", now: now) } ?? "")
    }

    /// "2 weeks ago · 2.2 MB · 181k tok" — the token run turns orange
    /// while the prompt cache is presumed warm.
    private var subtitle: Text {
        let base = Text(
            transcript.modifiedAt.formatted(.relative(presentation: .named))
                + " · " + transcript.size.formatted(.byteCount(style: .file)))
        guard let usage else { return base }
        return base
            + warmTokenText(
                " · " + tokenLabel(usage.contextTokens) + " tok", usage: usage, now: now)
    }
}

/// "412", "263k", "1.3M" — sidebar-density token counts.
private func tokenLabel(_ count: Int64) -> String {
    switch count {
    case ..<1_000: "\(count)"
    // The k form rounds, so the boundary belongs where the rounding lands,
    // not where the number does: 999,500 reads as "1000k" otherwise, which
    // is both wider than the column and a unit nobody uses.
    case ..<999_500: "\((count + 500) / 1_000)k"
    default: String(format: "%.1fM", Double(count) / 1_000_000)
    }
}

/// A token-count run that turns orange while the cache is presumed
/// warm; time-based, so each heartbeat re-render lets it cool off.
private func warmTokenText(_ label: String, usage: ContextUsage, now: Date) -> Text {
    guard usage.isWarm(now: now) else { return Text(label) }
    return Text(label).foregroundStyle(.orange)
}

/// Row tooltip; `verb` names the act the cost applies to — "resume"
/// for history rows, "next turn" for live ones.
private func warmthHint(_ usage: ContextUsage, verb: String, now: Date) -> String {
    let tokens = tokenLabel(usage.contextTokens)
    guard usage.isWarm(now: now) else {
        return "Cache cold — \(verb) reprocesses ~\(tokens) tokens uncached"
    }
    let minutes = max(1, Int(usage.warmUntil.timeIntervalSince(now) / 60))
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
