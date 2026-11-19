# Agent workspace evidence

Real frames from the Debug app, captured with `ScreenshotDriver` against a
throwaway support directory, defaults suite and keychain service. The demo board
(`DemoSeed`) supplies the tasks, meetings, transcripts and a generated 20-second
WAV; nothing here is a mock rendered outside the app.

## Frames

| File | What it proves |
|---|---|
| `20-agent-tasks-light.png` | "What's on my todo?" returns task cards from the store, with priority, notes, due date, tags and Open/Complete actions. |
| `21-agent-meetings-light.png` | "Show my recent meetings" returns real meeting rows with date, duration, status, participants, summary excerpt and Open/Summary/Play actions. |
| `22-agent-summary-light.png` | "Summarize it" resolves the meeting list context and renders summary, key points, decisions, action items, linked tasks and transcript timestamps. |
| `23-agent-participants-light.png` | "Who was in it?" resolves "it" and cross-references participants with their action items and tasks. |
| `24-agent-transcript-light.png` | The transcript card shows real segments, speakers and clickable timecodes. |
| `25-agent-action-items-light.png` | Action items join to their meeting and to real tasks; suggested/added/dismissed states and Add Task/Open Task/Restore are visible. |
| `26-agent-recording-light.png` | "Find my last recording" selects the most recent playable meeting and shows a recording card. |
| `27-agent-playing-light.png` | "Play its recording" starts the real AVFoundation player; pause state, position and PLAYING are live. |
| `28-agent-opened-meeting-light.png` | "Open the design review meeting" navigated to the actual Meetings screen; the shared player bar is on the meeting page. |
| `29-agent-proposal-light.png` | A create task command produced a validated proposal in PROPOSED OPERATIONS with a friendly due date. |
| `30-agent-compact-light.png` | The workspace at 780×600 with the operations panel open: header, transcript, cards, composer and panel all fit. |
| `31-agent-executed-light.png` | EXECUTE applied the operation through `TaskService`; the receipt and "AGENT UPDATED THE BOARD" confirm it. |
| `32-agent-after-execute-light.png` | A follow-up read shows the new task in TODO, proving the write is visible to retrieval. |
| `33-agent-dark.png` | Dark mode keeps the same hierarchy and contrast. |

## Re-capture

```
cd kanban
xcodebuild -project Kanban.xcodeproj -scheme Kanban -destination 'platform=macOS,arch=arm64' build

KANBAN_SUPPORT_DIR=$(mktemp -d) \
KANBAN_DEFAULTS_SUITE=com.kanban.evidence.agent.$$ \
KANBAN_KEYCHAIN_SERVICE=com.kanban.evidence.agent \
KANBAN_DEMO_DATA=1 KANBAN_SCREENSHOT_DIR=/tmp/agent-shots \
KANBAN_AUTO_QUIT=1 \
"$(xcodebuild -project Kanban.xcodeproj -scheme Kanban \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/Kanban.app/Contents/MacOS/Kanban" \
-ApplePersistenceIgnoreState YES
```

`ScreenshotDriver` walks the flow in `20`–`33`; run it against a fresh support
directory so `DemoSeed` runs.

## Limit

These are static frames of the real view hierarchy. Audio is a generated silent
WAV, so loudness is not assessed; VoiceOver traversal, Reduce Motion playback and
microphone permission still need an on-device pass. The backend stream route is
covered by `kanban-backend/tests/test_meetings_pipeline.py`.
