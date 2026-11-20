import Foundation

/// Gmail's on-device cache. It lives in the same SQLite file as the board so one
/// backup, one directory and one storage policy cover both, but it is entirely
/// independent of the VPS: nothing here is ever sent to the Work Console backend.
enum GmailSchema {

    static func create(_ db: SQLiteDatabase) throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS gmail_accounts (
                id TEXT PRIMARY KEY,
                email TEXT NOT NULL,
                display_name TEXT NOT NULL DEFAULT '',
                history_id TEXT,
                last_sync REAL,
                sync_error TEXT,
                created REAL NOT NULL,
                updated REAL NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_gmail_accounts_email ON gmail_accounts(email);

            CREATE TABLE IF NOT EXISTS gmail_labels (
                account_id TEXT NOT NULL REFERENCES gmail_accounts(id) ON DELETE CASCADE,
                id TEXT NOT NULL,
                name TEXT NOT NULL,
                type TEXT NOT NULL DEFAULT 'user',
                unread INTEGER NOT NULL DEFAULT 0,
                total INTEGER NOT NULL DEFAULT 0,
                color_text TEXT,
                color_bg TEXT,
                PRIMARY KEY (account_id, id)
            );

            CREATE TABLE IF NOT EXISTS gmail_threads (
                account_id TEXT NOT NULL REFERENCES gmail_accounts(id) ON DELETE CASCADE,
                id TEXT NOT NULL,
                subject TEXT NOT NULL DEFAULT '',
                snippet TEXT NOT NULL DEFAULT '',
                last_date REAL NOT NULL,
                message_count INTEGER NOT NULL DEFAULT 0,
                unread_count INTEGER NOT NULL DEFAULT 0,
                starred INTEGER NOT NULL DEFAULT 0,
                has_attachments INTEGER NOT NULL DEFAULT 0,
                labels TEXT NOT NULL DEFAULT '[]',
                participants TEXT NOT NULL DEFAULT '[]',
                PRIMARY KEY (account_id, id)
            );
            CREATE INDEX IF NOT EXISTS idx_gmail_threads_date
                ON gmail_threads(account_id, last_date DESC);

            CREATE TABLE IF NOT EXISTS gmail_thread_labels (
                account_id TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                label_id TEXT NOT NULL,
                PRIMARY KEY (account_id, thread_id, label_id),
                FOREIGN KEY (account_id, thread_id)
                    REFERENCES gmail_threads(account_id, id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_gmail_thread_labels_label
                ON gmail_thread_labels(account_id, label_id);

            CREATE TABLE IF NOT EXISTS gmail_messages (
                account_id TEXT NOT NULL,
                id TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                history_id TEXT,
                internal_date REAL NOT NULL,
                from_name TEXT NOT NULL DEFAULT '',
                from_email TEXT NOT NULL DEFAULT '',
                to_json TEXT NOT NULL DEFAULT '[]',
                cc_json TEXT NOT NULL DEFAULT '[]',
                bcc_json TEXT NOT NULL DEFAULT '[]',
                reply_to_json TEXT NOT NULL DEFAULT '[]',
                subject TEXT NOT NULL DEFAULT '',
                snippet TEXT NOT NULL DEFAULT '',
                body_text TEXT NOT NULL DEFAULT '',
                body_html TEXT,
                size_estimate INTEGER NOT NULL DEFAULT 0,
                is_draft INTEGER NOT NULL DEFAULT 0,
                is_unread INTEGER NOT NULL DEFAULT 0,
                is_starred INTEGER NOT NULL DEFAULT 0,
                label_ids TEXT NOT NULL DEFAULT '[]',
                rfc_message_id TEXT,
                references_json TEXT NOT NULL DEFAULT '[]',
                PRIMARY KEY (account_id, id),
                FOREIGN KEY (account_id, thread_id)
                    REFERENCES gmail_threads(account_id, id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread
                ON gmail_messages(account_id, thread_id, internal_date);
            CREATE INDEX IF NOT EXISTS idx_gmail_messages_from
                ON gmail_messages(account_id, from_email);
            CREATE INDEX IF NOT EXISTS idx_gmail_messages_date
                ON gmail_messages(account_id, internal_date DESC);

            CREATE TABLE IF NOT EXISTS gmail_attachments (
                account_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                id TEXT NOT NULL,
                filename TEXT NOT NULL DEFAULT '',
                mime_type TEXT NOT NULL DEFAULT 'application/octet-stream',
                size INTEGER NOT NULL DEFAULT 0,
                content_id TEXT,
                is_inline INTEGER NOT NULL DEFAULT 0,
                local_path TEXT,
                PRIMARY KEY (account_id, message_id, id),
                FOREIGN KEY (account_id, message_id)
                    REFERENCES gmail_messages(account_id, id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_gmail_attachments_message
                ON gmail_attachments(account_id, message_id);

            CREATE TABLE IF NOT EXISTS gmail_drafts (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES gmail_accounts(id) ON DELETE CASCADE,
                gmail_draft_id TEXT,
                gmail_message_id TEXT,
                thread_id TEXT,
                to_json TEXT NOT NULL DEFAULT '[]',
                cc_json TEXT NOT NULL DEFAULT '[]',
                bcc_json TEXT NOT NULL DEFAULT '[]',
                subject TEXT NOT NULL DEFAULT '',
                body_text TEXT NOT NULL DEFAULT '',
                body_html TEXT,
                attachments_json TEXT NOT NULL DEFAULT '[]',
                in_reply_to TEXT,
                references_json TEXT NOT NULL DEFAULT '[]',
                created REAL NOT NULL,
                updated REAL NOT NULL,
                status TEXT NOT NULL DEFAULT 'local'
            );
            CREATE INDEX IF NOT EXISTS idx_gmail_drafts_account
                ON gmail_drafts(account_id, updated DESC);

            CREATE TABLE IF NOT EXISTS gmail_outbox (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL REFERENCES gmail_accounts(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                message_id TEXT,
                thread_id TEXT,
                payload BLOB,
                created REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_gmail_outbox_account
                ON gmail_outbox(account_id, id);

            CREATE TABLE IF NOT EXISTS gmail_embeddings (
                account_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                vector BLOB NOT NULL,
                updated REAL NOT NULL,
                PRIMARY KEY (account_id, message_id),
                FOREIGN KEY (account_id, message_id)
                    REFERENCES gmail_messages(account_id, id) ON DELETE CASCADE
            );

            CREATE VIRTUAL TABLE IF NOT EXISTS gmail_fts USING fts5(
                message_id UNINDEXED,
                account_id UNINDEXED,
                subject,
                sender,
                recipients,
                body,
                tokenize = 'porter unicode61'
            );
            """)
    }
}
