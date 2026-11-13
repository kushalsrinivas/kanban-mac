# Visual evidence

Real screenshots of the running app. `before/` is `main` at `8a0100c`; `after/` is the
`production-hardening` branch. Both sets were captured at the same 1160×760 window.

## How they were captured

`scripts/capture-visual-evidence.sh after` builds the Debug app and launches it with:

- a throwaway support directory (`KANBAN_SUPPORT_DIR`),
- a throwaway defaults suite and keychain service,
- deterministic demo tasks and meetings (`DemoSeed`, Debug-only),
- `ScreenshotDriver`, which walks the main screens, renders each window's own view
  hierarchy to PNG, and quits.

The same harness was applied to a worktree of `main` for `before/`. The only harness
change in that worktree was normalising the window resizability so both sets are
1160×760: `main` used `.contentSize`, which clamped the window to its 928pt content
ideal and cut the fourth column off at launch. The branch uses `.contentMinSize`.

The demo data is fictional and the real board, preferences and keychain are never
touched.

## What changed visually

| Screen | Before | After |
|---|---|---|
| Window | Opened at 928pt; DONE was off-screen from launch. | Opens at the intended 1160pt; all four columns are visible. |
| Board | Fixed 248pt columns hugged the left. | Columns fill the window (248–340pt) and stay on one row; they scroll only when the window or inspector leaves less room. |
| Board copy | “1 SUGGESTED TASKS”; `MEETINGS 1!` | “1 SUGGESTED TASK”; `MEETINGS • 1` with a review dot and tooltip |
| Board contrast | Tertiary metadata 2.49:1; card outlines ~1.4:1. | Text ≥4.5:1; cards and controls ≥3:1; decorative rules stay hairline. |
| Inspector | Edit fields low contrast; COMPLETE/ARCHIVE/DELETE below the fold. | Control boundaries visible; the action row is pinned to the bottom; the board scrolls the selected card into view. |
| Quick add | Placeholder mono, value proportional; input jumped on the first keystroke. | One mono size for prompt and value; visible field boundary. |
| Command palette | Group labels wrapped (`MEETIN` / `G`). | One-line groups with a 56pt label column. |
| Agent | Status truncated to `NOT CONFIGU…`; SEND looked enabled with no backend. | Full `NOT CONFIGURED`; SEND disabled when unavailable; OPEN SETTINGS CTA; examples only shown when usable. |
| Meetings | Completed detail only. | Same layout with a capped reading measure; processing/interrupted/local-only states exist in source and tests. |
| Meeting detail | Summary ran ~125 characters per line. | Reading column capped at 640pt; action cards and headers keep the full width. |
| Settings | `1 RECORDS`, PURGE only; VPS below an invisible fold. | `1 RECORD`, RESTORE… and confirmed PURGE; VPS moved above meetings; scrollbar restored. |
| Badges | AGT/MTG and DESTRUCTIVE at 8–8.5pt. | 9.5pt minimum for information badges. |
| Dark mode | Same inversion, low-contrast tertiary and dim signal. | Readable metadata and signal; active-tab dot uses paper for contrast. |
| Compact 780×520 | Status module clipped; no indication of missing columns. | Metrics compressed; board scrolls and follows ⌘1–4; the right-edge clip at the capture size is documented. |
| Wide 1440×900 | Board hugged the left. | Columns expand to their cap and stay aligned with the gutter. |

## Files

`before/` and `after/` each contain:

1. board (light)
2. quick add with parsed hint
3. search with no-match columns
4. command palette
5. meetings list
6. completed meeting detail
7. agent console
8. inspector
9. settings
10. board (dark)
11. meeting detail (dark)
12. inspector (dark)
13. settings (dark)
14. board at 780×520
15. board at 1440×900

## Limits

- These are static frames. Interaction recordings were not captured: the UI-test
  runner was blocked by a macOS Automation permission prompt after a restart. The
  self-capture harness replaced it and renders the real window hierarchy.
- Animations are verified by source and by the Reduce Motion branches, not by video.
- ScreenCaptureKit, microphone permission and VoiceOver runtime behaviour still need
  an on-device pass.
