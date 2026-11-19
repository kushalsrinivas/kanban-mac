# Local scheduling evidence

Real Debug-app frames of the Mac-only scheduling flow. Nothing here calls the VPS or
an external calendar. The demo board (`DemoSeed`) supplies two scheduled meetings and
their history; the agent writes the third through the same store the Calendar uses.

| File | What it proves |
|---|---|
| `34-calendar-light.png` | The Calendar section reads `scheduled_meetings` from SQLite, groups upcoming/past, shows local briefs, conflicts, open items and decisions. |
| `35-agent-calendar-light.png` | "What's on my calendar?" returns scheduled meeting cards with date, time, people, location and Open/Brief actions. |
| `36-agent-brief-light.png` | "Prepare me for my next meeting" builds a brief from local recordings, action items and decisions: related conversation, conflicts, better times, unresolved questions. |
| `37-agent-schedule-proposal-light.png` | "Schedule a meeting about onboarding with Sarah tomorrow at 2pm for 45 minutes" parses a draft and puts it in PROPOSED OPERATIONS. Nothing is written yet. |
| `38-agent-scheduled-light.png` | EXECUTE persists the meeting locally, shows the receipt, and renders a Scheduled artifact with Open Calendar/Brief. |
| `39-calendar-scheduled-light.png` | The new meeting appears in the real Calendar screen, selected, with its brief built from existing history. |
| `40-calendar-dark.png` | Dark-mode consistency for the schedule and brief. |

## What is local

- `scheduled_meetings` is a SQLite table in the Mac store (`Schema` v3).
- The agent creates a `ScheduledMeetingDraft`; it is not written until EXECUTE.
- Briefs use `MeetingMemory`/`ScheduledBriefBuilder` over meetings, action items and
  tasks already on the Mac.
- Optionally, `CalendarBridge` reads system calendars through EventKit. Those events
  are read-only and appear in the same list; the app never writes to them.

## Re-capture

Use the same harness as `VisualEvidence/agent-workspace/README.md`; `ScreenshotDriver`
captures `34`–`40` after the agent flow.
