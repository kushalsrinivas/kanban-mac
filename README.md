# Work Console — macOS app

A Kanban board, a meeting recorder and an agent console, built as one native macOS
utility. Backend lives in [`kanban-backend`](../kanban-backend).

The Mac does what only the Mac can do: draw the interface, take keyboard input, and
capture audio. Transcription, analysis and agent reasoning all happen on the VPS.

## Running it

```
brew install xcodegen
xcodegen generate
open Kanban.xcodeproj
```

Then ⌘R. `Kanban.xcodeproj` is generated from `project.yml` and is not committed.

Signing is ad-hoc (`CODE_SIGN_IDENTITY = "-"`), so it builds and runs with no
provisioning profile. Swap in your team in `project.yml` to notarise.

Without a backend configured the app is a complete local task manager: the board,
search, the palette and recording all work. Set Settings → VPS to add meetings
processing and the agent.

## Layout

```
Sources/
├── Shared/              compiled into the app, the widget and the tests
│   ├── Core/Models      Task, Meeting, dates, quick-add parsing
│   ├── Core/Database    SQLite wrapper, schema, the local cache + outbox
│   ├── Core/Networking  wire DTOs, the local task service
│   ├── Design           the visual system
│   └── Snapshot         the small file the widget reads
├── Kanban/              the app
│   ├── Core/            API client, SSE, Keychain, sync engine, notifications
│   ├── Tasks/           board, cards, inspector, quick add
│   ├── Meetings/        recorder, capture engine, processing, results, suggestions
│   ├── Agent/           the console
│   ├── MenuBar/  Settings/  App/
└── KanbanWidget/        Today widget
```

## How state works

The VPS is the source of truth. The Mac keeps a SQLite **cache with an outbox**:

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
sends it to the VPS for transcription, without a second press. If the VPS is unreachable
the recording waits on disk and goes up when the connection returns. The audio is kept
after processing; turn off "keep recordings" to treat it as a transport file and reclaim
the space instead.

Turn off **AUTO UPLOAD** in Settings and nothing leaves this Mac until you press PROCESS
on a specific recording — per meeting, "Keep Local Only" does the same thing.

Deleting a meeting deletes it everywhere: the audio file, the local row and its
transcript, and the copy on the VPS. The server delete is queued rather than sent
directly, so deleting while offline still lands once the connection returns. "Delete
Recording File" drops just the audio and keeps the notes, and Settings can clear every
saved recording at once (skipping anything still waiting to upload).

`AudioCaptureEngine` is a protocol, so chunked streaming can replace file-then-upload
without touching the meeting flow.

## Meeting action items never become tasks on their own

The VPS extracts action items. They arrive as *suggestions*. You press ADD, adjust the
title, status, priority and due date, and confirm. ADD ALL skips the per-item dialog,
not the decision. A task created this way keeps a link back to the meeting it came from,
and deleting it puts the suggestion back.

## The agent

Reads answer inline. Writes come back as structured operations with a one-line summary,
and sit there until you press EXECUTE. The Mac never interprets them — the server
validated and described each one. Destructive operations are marked.

## Keyboard

| | |
|---|---|
| `⌘N` | new task (focuses quick add) |
| `⌘K` | command palette |
| `⌘F` | search |
| `⌘1`–`⌘4` | focus a column |
| `⌘⇧1`–`⌘⇧4` | move the selected task |
| `⌘R` | start / stop recording |
| `⌘⌥1/2/3` | tasks / meetings / agent |
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

64 tests: store and migrations, the outbox, the task service, wire DTOs, date and
quick-add parsing, snapshot generation, capture-source reporting.

`FixtureGenerator` writes `Tests/Fixtures/*.json` from the real encoders. Run
`scripts/sync-contract-fixtures.sh` to copy them into the backend repo, whose suite
asserts against those exact bytes. That is what keeps the two repos honest with each
other.

## Design

Translated from an industrial control-panel reference: warm off-white paper, near-black
ink, 1px rules, generous whitespace, monospace for every number and status, uppercase
micro-labels. Priority is a bar glyph, not a colour. The only animation in the app is
the recording indicator, because that one needs to read as live.

Dark mode keeps the same language rather than inverting into neon.
