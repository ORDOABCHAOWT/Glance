# CodexTouchBar

A lightweight native macOS companion that shows Codex or Claude Desktop tasks and remaining quota as colored glass blocks on MacBook Pro Touch Bar models. Version 0.2.7 fixes a Claude session monitor shutdown deadlock and keeps Claude usage live instead of falling back to stale history.

## Features

- Up to six active Codex desktop or CLI tasks, detected from local status metadata and showing the same compact display title as Codex's task list, plus phase and elapsed time. Request bodies are never used directly as labels. Blocks expand into unused Touch Bar space and compress equally as more tasks appear.
- The app bundle includes the supplied Codex Touch Bar icon.
- Tap any task block to open its exact `codex://threads/<id>` page in the Codex desktop app.
- Five-hour and weekly remaining quota, including reset time, from the official local Codex App Server protocol.
- A Monterey-style glass treatment: flat translucent color, a fine luminous border, and rounded corners—without gradients.
- Actual previous, play/pause, and next-track controls grouped together on the left, without Accessibility or Input Monitoring permission.
- Native AppKit button hit-testing and press feedback for every interactive control; the first physical touch sends the action and status blocks fill the available Touch Bar region proportionally.
- The private modal bar follows the foreground Codex or Claude Desktop app and is dismissed for other apps, restoring the system Touch Bar.
- A built-in on-screen preview that uses the exact same views as the physical Touch Bar.
- No prompt or transcript collection. No third-party runtime dependencies.

## Important Touch Bar limitation

Apple only exposes public Touch Bar APIs to the foreground app. Persistent presentation while Codex is foreground therefore uses dynamically resolved, undocumented DFRFoundation and AppKit selectors. The app falls back to its on-screen preview if those APIs are unavailable after a macOS update.

## Claude Desktop setup and behavior

The same app supports ordinary chats, Claude Code, and Cowork. No separate companion process is needed.

1. Sign into Claude Code with the same account used in Claude Desktop. If the existing login is expired, run `/login` in Claude Code yourself.
2. Usage normally needs no setup. The token is read through `/usr/bin/security`, which the Keychain item already trusts because Claude Code writes it with that tool, so there is no prompt and ad-hoc re-signing does not break access. Claude Desktop never refreshes Claude Code's login, so when the token has expired or is rejected the app runs `claude -p /usage` at most every 5 minutes: a local command that sends no model request and saves no session, but lets Claude Code refresh its own token. If that still fails, run `/login` in Claude Code, or choose **连接 Claude 用量…** to approve the in-app Keychain lookup.
3. Optional: choose **启用 Claude 侧栏任务访问**, then enable CodexTouchBar in macOS **Privacy & Security → Accessibility** to also read and press ordinary chat/Cowork sidebar rows. Keep the Claude sidebar open. Claude Code sessions need no permission.

The local bundle is ad-hoc signed. Replacing it may invalidate its Accessibility approval even if Settings still shows the old switch enabled. Re-register the installed app in Accessibility when needed. Missing permission displays **需要辅助功能权限**, rather than claiming no task is running. The `--resident-state-check` diagnostic queries the running companion and returns only permission/provider state, task counts, and safe Claude quota diagnostics: source, stale state, last update time, a fixed error category, and the existing user-facing error message; a separate CLI scan may inherit a different responsible process’s permission.

Claude Code sessions refresh every second. While Claude is foreground, sidebar rows refresh every 5 seconds. Usage refreshes every 60 seconds; returning to Claude requests a refresh if the last attempt was at least 30 seconds ago. Automatic requests pause in the background. Tap either Claude quota block for an immediate manual refresh. Requests cannot overlap; failures back off from 60 seconds to at most 15 minutes.

Quota blocks show **remaining** percentages (`余`), not the used percentages shown in Claude's settings. The network source is Claude Code's signed-in account, which the companion cannot independently prove matches the Desktop account. Its scoped OAuth token is read from the existing Keychain item only into memory and sent only to Anthropic's usage endpoint; redirects, cookie storage and disk caching are disabled. This endpoint and Claude's local metadata formats are internal interfaces observed in the installed Desktop app, so future Claude updates may require compatibility fixes.

If network usage is unavailable, the app can show Claude Desktop's local plan history. That history is sampled by Claude itself (observed roughly every 15 minutes), so polling it faster does not make it real time. Such values always carry **旧**; the preview and tooltips retain the actual sample timestamp, source and refresh error. Old successful network values are also marked stale after 2 minutes or a refresh error. Missing data displays `…`, never zero; history does not supply reset times.

Claude task snapshots continue to read the last selected Claude provider while the status menu or preview temporarily holds focus.

The bar displays up to six tasks. Claude Code sessions come first, from the live registration Claude Code keeps for each running session (`~/.claude/sessions/<pid>.json`), so they need no Accessibility permission. Each block shows the session's sidebar title, its phase and the time since the task started, like a Codex task: `busy` is 思 (thinking), `shell` is 工 (running a command), and `waiting` is 批 for a permission prompt or 等 for a question. A finished turn shows 成 for 12 seconds; idle sessions are not shown. Registrations whose process has exited, or whose pid was reused by another process, are ignored. Tapping a block opens that exact session through Claude Desktop's own `claude://code/continue?session=local_…` link.

Sidebar rows add ordinary chats and Cowork when Accessibility is granted, using their live Accessibility elements; a row whose title matches a Claude Code session is the same task and is not shown twice. Only the currently exposed sidebar list is available; it is not an inventory of every historical chat. Sidebar rows have no reliable start time, so they show the title only. Only explicit running, tool-use, waiting-for-input, or approval states are included; idle, completed, unknown, and historical Cowork records are excluded. When no active task exists, the task area displays **等待任务**.

From each registration the app decodes only the pid, desktop session ID, title, status and times. It never opens the sibling `.key` files or reads working directories, sockets, message bodies or transcript files, and never writes task data or credentials to disk.

For safe local preview alongside the installed app:

```bash
dist/CodexTouchBar.app/Contents/MacOS/CodexTouchBar --preview-only --provider claude --preview
```

Preview-only does not install a Touch Bar, start the Codex socket/client, or poll network usage automatically. Explicitly clicking a quota block or the connection menu still requests usage. A provider pin affects only the preview.

## Build and test

```bash
swift run CodexTouchBarCoreChecks
./scripts/build_app.sh
```

The app bundle is written to `dist/CodexTouchBar.app`.

The layout follows Apple's Touch Bar guidance: use AppKit controls and convenience sizing, let the system manage constrained composition, and use a principal item instead of hard-coded centering. See Apple's [NSTouchBar](https://developer.apple.com/documentation/appkit/nstouchbar?changes=l_11), [NSTouchBarItem](https://developer.apple.com/documentation/appkit/nstouchbaritem?language=objc), and [Buttons HIG](https://developer.apple.com/design/human-interface-guidelines/buttons).

## Task status connection

Launch the app, then choose **Install Codex Status Connection** from its menu. The app adds a clearly marked block to `~/.codex/config.toml`, leaving a Harness-managed `hooks.json` symlink and all unrelated settings untouched. Removing the connection deletes only that marked block.

## Privacy model

The hook helper accepts only:

- session id
- turn id
- hook event name
- workspace basename
- canonical tool name
- event time

It ignores transcript paths, absolute working directories, prompts, responses, tool inputs, tool outputs, models, and permission mode. Status is transferred through a user-only Unix socket and kept in memory. The desktop-task fallback reads only task IDs and timestamps from Codex's local log index, then resolves the compact `display_title` maintained by Codex's local task catalog. It never uses generated database `title`, `preview`, first-message, or log-body fields as labels, and never writes task data to disk.

## Third-party acknowledgement

The private Control Strip technique was cross-checked against Alexsander Akers' MIT-licensed `touch-baer` example. No third-party source is bundled at runtime.
