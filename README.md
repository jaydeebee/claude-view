# Claude View

A native macOS viewer for [Claude Code](https://code.claude.com) sessions.

Claude View is an adjunct to the Claude Code TUI, not a replacement: the TUI stays
the input surface, while Claude View renders session transcripts live so recent
history stays reviewable even when the terminal backlog is lost. Activities,
thinking, and tool calls expand and collapse; subagent runs render as nested
sub-sessions; every row can be flipped over to inspect the raw transcript entry.

## How it works

Claude Code writes everything Claude View needs to `~/.claude`:

```
~/.claude/
├── sessions/<pid>.json                live-session registry (pid, status, name)
├── projects/<project-slug>/           one dir per working directory
│   ├── <session-uuid>.jsonl           transcript — append-only JSONL
│   └── <session-uuid>/subagents/
│       ├── agent-<id>.jsonl           one transcript per subagent
│       └── agent-<id>.meta.json       join key back to the spawning tool call
└── session-env/<session-uuid>/        per-session scratch
```

The viewer watches those directories with FSEvents and tails transcripts
incrementally. A logical **session** is assembled from files with four join keys:

1. registry entry ↔ transcript, by `sessionId`
2. subagent file ↔ spawning `Task` tool call, by `meta.json` `toolUseId`
3. assistant entries → one API message, by `message.id`
   (each content block — text, thinking, tool call — is its own JSONL line)
4. `tool_result` ↔ `tool_use`, by `tool_use_id`

Rows render in file order; `parentUuid` is lineage metadata, not render order.
The transcript format is internal to Claude Code and unstable across releases,
so parsing is deliberately tolerant: unknown entry types degrade to raw-JSON
rows instead of errors.

## Architecture

| Layer | Role |
|---|---|
| `FileStore` | watchers + tailers; emits raw entries per file |
| `SessionAssembler` | applies the join keys; produces the logical session model |
| UI | session-first presentation, with a raw file/entry inspector underneath |

Read-only by design (v1). A later version may relay input back into sessions —
headless slash commands and Claude Code's cross-session messaging socket make
that feasible without changing this architecture.

## Building

```sh
swift build          # or: swift run ClaudeView
swift test
```

Requires a current macOS and Xcode toolchain. No third-party dependencies.

## Roadmap

- [ ] Charter: README, license, scaffolding
- [ ] Tolerant transcript-entry model
- [ ] Incremental JSONL tailer
- [ ] Live-session registry + liveness
- [ ] FSEvents watchers + session discovery
- [ ] Session assembler (message grouping, tool pairing, subagent linking)
- [ ] Sidebar: live sessions first, per-project history
- [ ] Transcript view: collapse/expand, live-follow, in-progress rows auto-open
- [ ] Raw JSON inspector; subagents as nested sub-sessions
- [ ] App bundle + signing script
- Later: richer Markdown rendering, file references as clickable links,
  input relay into sessions

## License

MIT — see [LICENSE](LICENSE).
