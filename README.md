# Work Console — macOS app

A Kanban board, a meeting recorder and an agent console, built as one native macOS
utility. Backend lives in [`kanban-backend`](../kanban-backend); the monorepo
overview is [`../README.md`](../README.md).

The Mac does the interface, the keyboard, and capture — and now the thinking too.
Transcription runs on-device through `transcribe.cpp`, the same ggml inference
engine and whisper GGUF models Handy uses; analysis and the agent call Gemini
directly with a key stored in the Keychain. A VPS is optional and only adds
multi-device sync.

## Running it

```
brew install xcodegen
xcodegen generate
open Kanban.xcodeproj
```

Then ⌘R. `Kanban.xcodeproj` is generated from `project.yml` and is not committed.

Signing is ad-hoc (`CODE_SIGN_IDENTITY = "-"`), so it builds and runs with no
provisioning profile. Swap in your team in `project.yml` to notarise.

Without any setup the app is a complete local task manager: the board, search, the
palette and recording all work. In Settings → Local AI, download a whisper model and
add a Gemini API key to transcribe and analyse meetings on this Mac and to use the
agent. Set Settings → VPS only if you want the optional server sync. The agent's
local reads, artifacts and confirmed writes work without it.

## Navigation

The main sections live in a left navigation drawer rather than a header tab strip.
It keeps the counts visible, marks anything that needs a decision, and collapses to
a 64pt icon rail (`⌃⌘S`) when the board needs the width. The choice is remembered
across launches.

## Layout

```
Sources/
├── Shared/              compiled into the app, the widget and the tests
│   ├── Core/Models      Task, Meeting, dates, quick-add parsing
│   ├── Core/Database    SQLite wrapper, schema, the local cache + outbox
│   ├── Core/Networking  wire DTOs, the local task service
│   ├── Meetings         local memory, commitments and automation engines
│   ├── Design           the visual system
│   └── Snapshot         the small file the widget reads
├── Kanban/              the app
│   ├── Core/            API client, SSE, Keychain, sync engine, notifications
│   ├── Core/AI/         Gemini client, action validation
│   ├── Core/Transcription  whisper engine, chunker, model catalog and downloads
│   ├── Tasks/           board, cards, inspector, quick add
│   ├── Meetings/        recorder, capture engine, processing, results, suggestions
│   ├── Calendar/        EventKit bridge, briefs, commitments, memory, automation
│   ├── Agent/           the console
│   ├── MenuBar/  Settings/  App/
├── MeetingsMCP/         the local stdio MCP server
└── KanbanWidget/        Today widget
```

## How state works

The SQLite database on this Mac is the source of truth. When a VPS is configured it
also becomes a **cache with an outbox**:

- Every mutation applies locally first, so the UI never waits on a network call.
- The same mutation is queued as a replayable HTTP request.
- The outbox drains when the connection returns; repeat edits to one task collapse to
  a single request. Ordering is preserved — a transient failure stops the queue rather
  than skipping ahead.
- A refresh never clobbers a row that still has queued changes.
- With no VPS configured, nothing is queued at all and the app is simply local.

This is deliberately not a second backend. It holds ordering and validation, nothing
more.

## Recording

Recording only ever starts because you pressed a button. There is no auto-detection and
no background listening — the engine exists only between START and STOP.

Microphone capture is AVAudioEngine, into a 32 kHz mono AAC file (~28 MB/hour), with
the main mixer muted so nothing is played back into the room. If a source is
unavailable the UI says so rather than silently recording half the meeting.

**The graph runs at the microphone's own sample rate**, decided per recording, and that
is not a detail. An `AVAudioMixerNode` will change an input's channel count happily, but
ask it to *resample* an input — a 44.1 kHz built-in mic feeding a 48 kHz mixer output —
and it emits digital silence: no error, no warning, and a tap that keeps firing on time
for the full length of the meeting. A hardcoded 48 kHz tap format is therefore silence
on every Mac whose microphone runs at 44.1 kHz, which includes the built-in one. System
audio gets the same treatment from the other side: ScreenCaptureKit is asked for the
graph's format and whatever it actually delivers is resampled to match rather than
dropped.

As a backstop, `AudioFileWriter` tracks the peak across the whole recording, and a file
with no signal anywhere in it is flagged rather than sent off to transcribe nothing.

**System audio is off by default**, and you probably do not need it. It exists to
capture the *other* side of a video call — without it you record the room and your own
voice, which is all an in-person meeting needs. Turning it on uses ScreenCaptureKit,
which means granting Screen Recording and living with the macOS capture indicator in
the menu bar. That is a real cost, so it is opt-in rather than assumed.

Everything on the capture path runs on realtime audio threads and touches only the
lock-protected `AudioFileWriter` — never main-actor state. STOP always tears the engine
down even if it disagrees about whether it is running, and FORCE STOP is there as an
unconditional escape hatch.

Stopping saves the recording to `~/Library/Application Support/Kanban/Recordings` and
starts transcribing it, without a second press. The recording is decoded to 16 kHz
mono and run through the loaded GGUF model by `transcribe.cpp`; the audio is never
uploaded. The resulting transcript goes to Gemini for structure when a key is
configured; without one the meeting finishes with its transcript and no analysis. If no
speech model is installed the recording waits on disk. The audio is kept after
processing; turn off "keep recordings" to treat it as a transport file and reclaim the
space instead.

The engine layer is a Swift port of Handy's: the bundled model catalog is the same
file (pinned revisions and per-quant SHA-256), downloads verify before they are
trusted, whisper's long-form decoding is one run, models that lose accuracy past
their window are cut at Silero-VAD pauses, language hints are validated against the
loaded model, and an idle engine unloads after five minutes. It lives in
`Sources/Kanban/Core/Transcription`.

The catalog (`Resources/Kanban/catalog.json`) and the Swift bindings under
`Vendor/TranscribeCpp` are Handy's and transcribe.cpp's, both MIT licensed.

Turn off **AUTO UPLOAD** in Settings and nothing leaves this Mac until you press PROCESS
on a specific recording — per meeting, "Keep Local Only" does the same thing.

Deleting a meeting deletes it everywhere: the audio file, the local row and its
transcript, and the copy on the VPS. The server delete is queued rather than sent
directly, so deleting while offline still lands once the connection returns. "Delete
Recording File" drops just the audio and keeps the notes, and Settings can clear every
saved recording at once (skipping anything still waiting to upload).

`AudioCaptureEngine` is a protocol, so chunked streaming can replace file-then-upload
without touching the meeting flow.


## Gmail (entirely client-side)

Mail is a first-class section in the app, next to Tasks, Meetings and Agent. It has
**no server component**: the Mac talks directly to Gmail, caches everything in the
same SQLite file, and never sends email content to the Work Console VPS or to an AI
service.

### Connecting

1. In Google Cloud Console, create (or pick) a project and enable the Gmail API.
2. Configure the OAuth consent screen and add your account as a test user.
3. Create Credentials → OAuth client ID → **Desktop app**.
4. Open Settings → Gmail, paste the client ID (and the client secret if Google shows
   one), and press CONNECT.

The app opens Google in the default browser, listens on `127.0.0.1` on a random port,
and completes the installed-app flow with PKCE and a random `state`. The redirect URI
is loopback only. Refresh and access tokens live in the login Keychain under the app's
Gmail service; the SQLite file never contains a token. Disconnecting revokes the
refresh token, removes the Keychain item, and deletes that account's cached messages,
drafts and attachments.

Scopes are `gmail.modify` and `gmail.send`. No contacts, calendar or Drive scope is
requested. Multiple accounts are supported; ALL ACCOUNTS is a view, not a shared
mailbox.

### Encryption at rest

- OAuth tokens, the optional client secret and the local AES-GCM key live in the
  Keychain, never in SQLite or UserDefaults.
- Draft subjects, bodies, recipients and attachment metadata are encrypted with
  AES-GCM before they reach SQLite; attachment files and their legacy plaintext
  copies are encrypted in place with the same device-local key. Decryption happens
  only in memory (or a short-lived `0600` file when you ask to reveal an attachment).
- Message threads and the FTS index stay in SQLite, so the app **requires FileVault**
  before mail is unlocked. On launch/activation it runs `fdesetup status`; if
  FileVault is off or cannot be verified, the Mail section is replaced by a lock
  screen, sync and the agent's mail tools are disabled, and connecting a new account
  is refused. Enabling FileVault and pressing RECHECK unlocks it.
- The encryption key is device-local. Resetting the login Keychain makes old local
  drafts/attachments unreadable; Gmail still holds the server copies.

### Sync and offline

- The first sync fetches the newest N messages (200/500/1K/2K in Settings) and the
  label list, then stores header, body, thread and attachment metadata.
- Later syncs use `users.history.list` with the stored `historyId`; a 404/expired
  cursor triggers one full resync. History pages are walked with `pageToken`.
- Opening a conversation fetches the full thread on demand if the local copy has fewer
  messages than Gmail's count.
- Attachment bytes are downloaded only when you press SAVE, and inline images only
  when a message is rendered. Files go under
  `~/Library/Application Support/Kanban/Gmail/Attachments/<account>` with 0700/0600
  permissions.
- Gmail changes are optimistic locally and queued in `gmail_outbox`. The queue is
  replayed in order when the network returns; repeat draft saves replace the queued
  draft instead of creating duplicates. A transient failure stops the queue rather
  than skipping ahead.
- Sending when offline queues the exact RFC 822 message; it is sent on the next sync.
- Delete moves a conversation to Gmail Trash. Permanent deletion is not exposed: it
  needs the full-mailbox `https://mail.google.com/` scope, and Meet deliberately asks
  only for `gmail.modify` + `gmail.send`. Gmail still auto-purges Trash on its schedule.
- Rate limits (429/403 quota) and 5xx responses are retried with backoff and
  `Retry-After`; a 401 refreshes the access token once and retries.

### Live verification checklist

The automated suite uses a fake Gmail API, so a first live run should cover:

1. Create a Google Cloud project, enable Gmail API, configure the consent screen and
   create a **Desktop app** OAuth client.
2. Settings → Gmail → Add account. Consent once; confirm the account appears with
   FILEVAULT ON and a token in the Keychain.
3. Press SYNC; send yourself a message from another client and confirm it arrives via
   the History sync. Open a thread and download an attachment.
4. Send a message from the composer (the confirmation dialog is the only send path).
   Confirm it appears in Sent and in Gmail.
5. Revoke the app's access in the Google account security page, press SYNC, and
   confirm the reconnect error. Reconnect and verify the cache resumes.
6. Disconnect. Confirm the refresh token is revoked and the account's local messages,
   drafts and encrypted attachments are gone.

### Reading, search and semantic ranking

Mailboxes: Inbox, Starred, Important, Sent, Drafts, Archive, Spam, Trash, All Mail,
plus user labels. Threads are stored with message-level labels, unread counts,
participants and attachment flags. Search understands Gmail-style operators
(`from:`, `to:`, `subject:`, `label:`, `is:unread`, `has:attachment`, `in:`,
`newer_than:`), and full message text is indexed with SQLite FTS5.

When the system English sentence embedding is available, an on-device semantic pass
can add paraphrases that FTS misses. The embedding model and the query run locally
through `NaturalLanguage`; the index is a vector BLOB in SQLite. No embedding request
leaves the Mac. Different search results are account-isolated.

HTML bodies are sanitized before display: scripts, styles, iframes, forms, event
handlers and `javascript:` URLs are removed, remote images are replaced with a
blocked marker, and a CSP meta tag plus a non-persistent WebView make remote loads
impossible. Clicking a link opens it in the default browser; the message view itself
never navigates.

### Composing

The composer is an `NSTextView` rich editor (bold, italic, underline, links, inline
images) with To/Cc/Bcc, subject, attachments and inline images. It builds a real
multipart/alternative + related + mixed MIME message with UTF-8 encoded headers,
base64 bodies, `Message-ID`, `In-Reply-To`, `References` and Gmail thread identity.
Reply, reply-all and forward prefill recipients, subject and quoted text. Drafts are
saved locally and pushed to Gmail Drafts; sending is always a separate confirmation.

### Agent

The existing agent console has local mail tools: search ("find the email where we
discussed pricing"), unread summary, latest conversation with a person, extracted
commitments ("what did this client promise?"), attention ranking, thread summaries
and label suggestions. Results are typed, clickable email artifacts that open the real
thread. Nothing in that path calls a model or a server.

The agent can propose draft creation, labeling, archiving, moving to trash and
marking read/unread. Every write appears in PROPOSED OPERATIONS and runs only after
EXECUTE. There is deliberately no send operation: only the composer's SEND button
(with its confirmation dialog) can send mail. Email content is never added to a
Gemini prompt.

### Meetings

A meeting page and a scheduled meeting page show related conversations matched on
participant names and email addresses from the local cache. A meeting can generate a
follow-up draft from its stored summary, decisions and action items; an upcoming
meeting can generate an agenda email. Email threads show their related recorded
meetings, so navigation works in both directions.

## Meeting action items never become tasks on their own

The analysis extracts action items. They arrive as *suggestions*. You press ADD, adjust the
title, status, priority and due date, and confirm. ADD ALL skips the per-item dialog,
not the decision. A task created this way keeps a link back to the meeting it came from,
and deleting it puts the suggestion back.

## The Meet workspace

`⌘⌥4` opens MEET: four local surfaces built on the same SQLite database. No VPS and
no model call is required to use them.

**Briefs.** Upcoming meetings come from two places: schedules the agent created, and
the Google/Outlook accounts macOS already has. The app reads EventKit, so adding the
account in System Settings → Internet Accounts is the whole integration — no OAuth
client or refresh token. Each brief answers four questions before you walk in: what
did we discuss last time, what did we promise, what decisions are still open, and does
this collide with anything. When there is a conflict it proposes open working-hour
slots. Briefs are generated for the next two weeks on launch, on app activation and
whenever the calendar refreshes, and a local notification fires 15 minutes before a
meeting with the one-paragraph summary.

**Commitments.** Every extracted action item also keeps the verbatim sentence that
made it and the transcript second it was said (`⌘`-click the timestamp to open the
transcript). The review state (suggested/added/dismissed) and the execution state
(open/done/cancelled) are separate, so dismissing a suggestion cannot complete a
promise. DONE on a commitment completes its linked board task, and reopening the
commitment reopens the task. REMIND composes a local notice and schedules the next
one at the due time.

**Memory.** Search across decisions, commitments, discussions, open questions and
raw transcript text for any date range or participant. ASK answers locally and
extractively, with citations, so it works offline; when a later decision reverses an
earlier one the answer explains both dates instead of silently returning the newest.
CONTRADICTIONS lists possible reversals as candidates, with the shared vocabulary
that caused the match. Nothing is presented as a fact the transcript does not support.

**Automation.** ADD STANDARD creates the rule from the product brief: draft a summary,
draft a follow-up, create tasks and notify commitment owners when a meeting ends.
Rules are editable rows — name, trigger, title/participant/duration conditions and
actions, including pushing tasks to an external project board through its incoming
webhook. A rule run writes an audit row; emails are composed as drafts in
DRAFTS & NOTIFICATIONS and open in the default mail client. Nothing is sent silently.

## Local MCP

`MeetMCP` is a stdio Model Context Protocol server over the same database, so another
agent can use the Mac's meeting memory when the app is closed and no server exists.

```
xcodebuild -project Kanban.xcodeproj -scheme MeetMCP build
# binary in DerivedData/Build/Products/Debug/MeetMCP
```

Point an MCP client at that path:

```json
{ "mcpServers": { "meet": { "command": "/absolute/path/to/MeetMCP" } } }
```

Set `KANBAN_SUPPORT_DIR` only if the app was run with a non-default support
directory. It exposes `search_meetings`, `get_meeting`,
`search_memory`, `ask_memory`, `list_commitments`, `complete_commitment`,
`create_task`, `list_upcoming_meetings`, `get_meeting_brief`,
`list_automation_rules` and `list_drafts`. Writes go through `TaskService` and
`LocalStore` — the same path the UI uses. The server build has a matching MCP
endpoint at `POST /api/v1/mcp` for the sync deployment.

## Dictation

Press **⌃⌥Space** anywhere on the Mac. A small floating card opens and starts
listening; it stops after two seconds of silence, or when you press the hotkey
again, and the transcript is put on the clipboard. The same on-device model as
meetings transcribes it — nothing is uploaded. The card never takes focus, so it
can sit over whatever you were typing in. Turn it off, or try it, in
Settings → Dictation.

## The agent

The console is a workspace over the real board, meetings and recordings, not a text
box. Reads are answered from the local SQLite cache, so they work offline and without
an API key: "what's on my todo", "show my recent meetings", "summarize the second one",
"what tasks came out of it", "find my last recording".

Answers are typed artifacts — task lists, meeting cards, structured summaries,
recording players, transcript snippets, action items and participant cards — rendered
by `AgentArtifactRegistry`. Each card links to the real destination (Open Meeting,
Open Task, Play Recording, View Transcript) and uses the app's existing routes.

Create, update, move and complete are real CRUD operations, not suggestions: the
planner produces a validated `AgentOperation` and the Mac applies it immediately.
Delete and archive still appear in PROPOSED OPERATIONS and wait for EXECUTE.
`AgentExecutor` is the single write path, so a typed command and a model proposal
cannot diverge. Invented ids and ambiguous selectors are dropped or answered with a
choice instead of guessed at.

Task phrasing carries its own reminder. "Create a todo to call Sarah tomorrow at
5pm" stores the task with a real 17:00 due time, removes the date phrase from the
title, applies the write, and arms the local notification for that time. "In 2
hours", "by friday" and "at 9am" work the same way.

Long prose is delegated to Gemini rather than forced through regexes: "add these
todos… one is X secondly Y then Z" returns one validated `create_task` per item and
applies them all. If the streaming reply is unreadable it retries the buffered
endpoint, and a malformed action is dropped without discarding the rest.
AUTO-APPLY WRITES in Settings turns the safe-write policy off.

Conversation state lives in `AgentContext`: the last meeting list, the last task list
and what "it" refers to. That is what makes "show my recent meetings" → "summarize
the second one" → "what tasks came out of it?" → "play its recording" work without
repeating the meeting name. The deterministic planner is consulted first; a model is
only asked after it reports a miss. A bare "the first one" also answers the
"Which meeting?" question the assistant just asked.

Scheduling is local, too. "Schedule a meeting about onboarding with Sarah tomorrow at
2pm for 45 minutes" becomes a pending `ScheduledMeetingDraft`; EXECUTE writes it to
the Mac's SQLite store and the MEET section opens it. Briefs are built from
meetings, action items, decisions and tasks already on the Mac. Optional EventKit
system-calendar events are read-only and never written by the app.

Open-ended Gemini turns stream the reply field from `streamGenerateContent?alt=sse`;
`AgentStreamParser` tolerates split JSON escapes and `AgentStreamReader` stops the
moment the user presses CANCEL, keeping the partial answer. Local deterministic
answers are atomic because they are SQLite reads. The VPS fallback still returns one
response: its LangGraph decision loop is not token-streamed.

## Keyboard

| | |
|---|---|
| `⌘N` | new task (focuses quick add) |
| `⌘K` | command palette |
| `⌘F` | search |
| `⌘1`–`⌘4` | focus a column |
| `⌘⇧1`–`⌘⇧4` | move the selected task |
| `⌘R` | start / stop recording |
| `⌘⇧M` | compose mail |
| `⌘⌥1`–`⌘⌥5` | tasks / meetings / mail / Meet / agent |
| `⌘⌥4` | meet (briefs, commitments, memory, automation) |
| `⌃⌘S` | collapse / expand the navigation drawer |
| `↑ ↓ ← →` | move the selection |
| `⌥↑ ⌥↓` | reorder within a column |
| `space` | complete |
| `⏎` | open |
| `⌫` | archive |

Quick-add syntax: `Fix auth bug !high #backend @friday >todo`.

## Tests

```
xcodebuild -project Kanban.xcodeproj -scheme KanbanTests \
  -destination 'platform=macOS,arch=arm64' test
```

284 tests at the time of writing (four live transcription tests and the fixture
generator are skipped unless explicitly enabled): store and migrations, the outbox,
the task service, wire DTOs, date and quick-add parsing, snapshot generation,
capture-source reporting, the agent planner/artifact engine, the shared agent
operation executor, the local meeting brain (commitment sources and task sync,
month-spanning memory search and cited answers, contradiction candidates, brief
conflicts and free-time suggestions, and local automation rules/drafts), plus Gmail
PKCE/loopback OAuth, MIME parse/build/sanitize, the Gmail cache and account
isolation, query operators, full-text/pagination, drafts, attachments, history sync
and fallback, outbox replay, send confirmation, and the email agent
artifacts/actions, app-level draft/attachment encryption, legacy-file migration,
the FileVault storage policy, the real Gmail HTTP client (auth header, 401 refresh,
429 retry, history expiry, attachment decoding, send thread identity), OAuth code
exchange/refresh/revoke, and token-manager persistence.

`FixtureGenerator` writes `Tests/Fixtures/*.json` from the real encoders, but only
when `KANBAN_WRITE_FIXTURES=1` is set — otherwise a test run would rewrite tracked
files. Run `scripts/sync-contract-fixtures.sh` to copy them into the backend repo,
whose suite asserts against those exact bytes. That is what keeps the two repos
honest with each other.

## Design

Translated from an industrial control-panel reference: warm off-white paper, near-black
ink, 1px rules, generous whitespace, monospace for every number and status, uppercase
micro-labels. Priority is a bar glyph, not a colour. The only animation in the app is
the recording indicator, because that one needs to read as live.

Dark mode keeps the same language rather than inverting into neon.
