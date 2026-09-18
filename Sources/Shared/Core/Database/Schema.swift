import Foundation

/// Schema for the on-device cache.
///
/// This is a *cache with an outbox*, not a second backend. The VPS is the source of
/// truth once configured; everything here exists so the UI is instant and the app
/// keeps working with no connection. Business logic beyond ordering and validation
/// belongs on the server.
enum Schema {

    static let version: Int32 = 2

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = db.userVersion

        if current < 1 {
            try createV2(db)
            db.userVersion = version
            return
        }

        if current < 2 {
            try upgradeV1toV2(db)
            db.userVersion = 2
        }

        // Keep the audit log bounded; this is a personal tool, not an audit system.
        try db.exec("DELETE FROM events WHERE id <= (SELECT MAX(id) - 500 FROM events);")
    }

    // MARK: Fresh install

    private static func createV2(_ db: SQLiteDatabase) throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                remote_id TEXT,
                title TEXT NOT NULL,
                notes TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'inbox',
                priority INTEGER NOT NULL DEFAULT 1,
                due REAL,
                tags TEXT NOT NULL DEFAULT '',
                position REAL NOT NULL DEFAULT 0,
                created REAL NOT NULL,
                updated REAL NOT NULL,
                completed REAL,
                archived REAL,
                source TEXT NOT NULL DEFAULT 'manual',
                meeting_id TEXT,
                action_item_id TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
            CREATE INDEX IF NOT EXISTS idx_tasks_due ON tasks(due);
            CREATE INDEX IF NOT EXISTS idx_tasks_meeting ON tasks(meeting_id);

            CREATE TABLE IF NOT EXISTS subtasks (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                done INTEGER NOT NULL DEFAULT 0,
                position REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_subtasks_task ON subtasks(task_id);

            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                remote_id TEXT,
                title TEXT NOT NULL,
                started REAL NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                status TEXT NOT NULL,
                audio_filename TEXT,
                uploaded REAL,
                processed REAL,
                failure TEXT,
                job_id TEXT,
                summary TEXT NOT NULL DEFAULT '',
                key_points TEXT NOT NULL DEFAULT '[]',
                decisions TEXT NOT NULL DEFAULT '[]',
                questions TEXT NOT NULL DEFAULT '[]',
                topics TEXT NOT NULL DEFAULT '[]',
                participants TEXT NOT NULL DEFAULT '[]'
            );
            CREATE INDEX IF NOT EXISTS idx_meetings_started ON meetings(started);

            CREATE TABLE IF NOT EXISTS action_items (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                assignee TEXT,
                due REAL,
                confidence REAL NOT NULL DEFAULT 0,
                state TEXT NOT NULL DEFAULT 'suggested',
                task_id TEXT,
                position REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_action_items_meeting ON action_items(meeting_id);

            CREATE TABLE IF NOT EXISTS transcript_segments (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                start REAL NOT NULL,
                finish REAL NOT NULL,
                speaker TEXT,
                text TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_segments_meeting ON transcript_segments(meeting_id, start);

            -- Mutations waiting to reach the VPS. Replayed in id order.
            CREATE TABLE IF NOT EXISTS outbox (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created REAL NOT NULL,
                kind TEXT NOT NULL,
                method TEXT NOT NULL,
                path TEXT NOT NULL,
                body BLOB,
                entity_id TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_outbox_entity ON outbox(entity_id);

            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL,
                actor TEXT NOT NULL,
                action TEXT NOT NULL,
                task_id TEXT,
                detail TEXT NOT NULL DEFAULT ''
            );
            """)
    }

    // MARK: v1 -> v2

    /// v1 stored the board column as `col` with 'active' for in-progress, and had no
    /// meeting tables. Migrate in place so an existing board is not lost.
    private static func upgradeV1toV2(_ db: SQLiteDatabase) throws {
        try db.transaction {
            try db.exec("""
                ALTER TABLE tasks RENAME TO tasks_v1;
                """)
            try createV2(db)
            try db.exec("""
                INSERT INTO tasks (id, title, notes, status, priority, due, tags, position,
                                   created, updated, completed, archived, source)
                SELECT id, title, notes,
                       CASE col WHEN 'active' THEN 'in_progress' ELSE col END,
                       priority, due, tags, position, created, updated, completed, archived,
                       'manual'
                FROM tasks_v1;
                DROP TABLE tasks_v1;
                """)
        }
    }
}
