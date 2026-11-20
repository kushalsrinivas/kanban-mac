# Gmail workspace — visual evidence

Captured from the real Debug app with `ScreenshotDriver`, a throwaway support
directory, defaults suite and keychain service. The Gmail data is fictional and is
written straight into the throwaway SQLite cache; no Google account or network call is
involved.

| File | Screen |
|---|---|
| `41-mail-inbox-light.png` | Mail workspace: accounts, mailboxes, labels, thread list, empty reading pane |
| `42-mail-thread-light.png` | Conversation with both messages expanded, attachments, reply/archive/trash actions |
| `43-mail-dark.png` | The same workspace in dark mode |
| `44-mail-compose-light.png` | Rich composer with To/Cc, subject, formatting, attachments and explicit SEND |
| `45-agent-email-unread-light.png` | Agent: local unread summary artifact |
| `46-agent-email-search-light.png` | Agent: local “pricing” search artifact |
| `47-agent-email-attention-light.png` | Agent: local attention ranking with reasons |
| `48-mail-filevault-locked.png` | Enforcement: Mail is locked when FileVault is off/unknown; drafts/attachments still AES-GCM |

The FileVault gate frame was captured with `KANBAN_ASSUME_FILEVAULT=off`
DEBUG-only, then the app's normal `fdesetup status` check in production. The other
frames used the host's real FileVault state.

The capture was produced with:

```
KANBAN_SUPPORT_DIR=/tmp/meet-mail-support \
KANBAN_DEFAULTS_SUITE=com.kanban.mail.evidence \
KANBAN_KEYCHAIN_SERVICE=com.kanban.mail.evidence \
KANBAN_DEMO_DATA=1 KANBAN_SCREENSHOT_DIR=/tmp/meet-mail-evidence \
KANBAN_AUTO_QUIT=1 Kanban.app/Contents/MacOS/Kanban
```

Limits: these are static frames. The real Google OAuth consent screen, live Gmail
sync, attachment downloads and actual delivery need an on-device run with a Google
Cloud desktop client; the automated suites cover the protocol, cache, sync, MIME,
queue and UI-independent behaviour.
