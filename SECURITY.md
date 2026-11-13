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
