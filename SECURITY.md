# Security

## Credential exposure: `.server-dump/`

`.server-dump/` previously held live credentials for the deployed service:
the VPS address, the Postgres password, the API token, a Gemini API key and a
database dump. No secret values are repeated here.

The directory is now listed in `.gitignore`, so it cannot be committed. It
was still present in the working tree when this note was written.

**Owner action required — treat all of it as compromised:**

1. Rotate `WC_API_TOKEN` and update the Mac app's Settings → VPS.
2. Rotate the Postgres password, then update `WC_DATABASE_URL` / `.env`.
3. Revoke and reissue the Gemini API key.
4. Delete `.server-dump/` once the secrets above no longer work.

An agent cannot perform these rotations; they need access to the provider
consoles and the running database.

## Gmail credentials

Gmail OAuth tokens are stored as generic-password items in the login Keychain under
the app's Gmail service, one item per account. They are not written to UserDefaults,
SQLite, `snapshot.json` or logs. The optional OAuth client secret is a separate
Keychain item. Mail content is cached locally in SQLite and attachments on disk;
FileVault is the at-rest protection for the SQLite message cache and FTS index; the
app verifies it with `fdesetup status` and locks mail when it is off or unknown.
Draft fields and attachment files are additionally AES-GCM encrypted with a random
256-bit key stored in the login Keychain. The key is device-local: resetting the
Keychain makes old local encrypted drafts/attachments unreadable, while Gmail retains
the server copies. Disconnecting an account revokes the refresh token and deletes its
local cache and attachment directory. Never commit
a client secret or a refresh token; the app asks for the client ID/secret at runtime.
