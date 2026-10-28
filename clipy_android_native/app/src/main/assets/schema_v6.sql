CREATE TABLE clipboard_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        content_hash TEXT UNIQUE,
        item_type TEXT NOT NULL,
        item_value TEXT NOT NULL,
        source_app TEXT,
        created_at INTEGER NOT NULL
      );

CREATE INDEX idx_clipboard_created ON clipboard_history(created_at DESC);

CREATE TABLE notifications (
        id TEXT PRIMARY KEY,
        notification_key TEXT,
        package_name TEXT NOT NULL,
        app_name TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT,
        body TEXT NOT NULL,
        post_time INTEGER NOT NULL,
        group_key TEXT,
        is_clearable INTEGER NOT NULL DEFAULT 1,
        is_archived INTEGER NOT NULL DEFAULT 0,
        sync_state INTEGER NOT NULL DEFAULT 0,
        extras_json TEXT NOT NULL DEFAULT '{}',
        synced_at INTEGER
      );

CREATE INDEX idx_notifications_package_time ON notifications(package_name, post_time DESC);

CREATE INDEX idx_notifications_post_time ON notifications(post_time DESC);

CREATE TABLE file_transfers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        sender_name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );

CREATE INDEX idx_file_transfers_created ON file_transfers(created_at DESC);

CREATE TABLE app_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        level TEXT NOT NULL,
        message TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );

CREATE INDEX idx_app_logs_created ON app_logs(created_at DESC);

CREATE TABLE IF NOT EXISTS pending_notification_sync (
        notification_id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        hash TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );

CREATE TABLE IF NOT EXISTS pending_text_sync (
        hash TEXT NOT NULL,
        data TEXT NOT NULL,
        type TEXT NOT NULL,
        target_peer_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE(target_peer_id, hash)
      );

CREATE INDEX IF NOT EXISTS idx_pending_text_sync_peer ON pending_text_sync(target_peer_id);

CREATE INDEX IF NOT EXISTS idx_pending_text_sync_hash ON pending_text_sync(hash);

CREATE TABLE IF NOT EXISTS pending_sync (
        peer_id TEXT NOT NULL,
        hash TEXT NOT NULL,
        type TEXT NOT NULL,
        data BLOB NOT NULL,
        enqueue_at INTEGER NOT NULL,
        PRIMARY KEY (peer_id, hash)
      );

CREATE INDEX IF NOT EXISTS idx_pending_sync_peer ON pending_sync(peer_id);

CREATE INDEX IF NOT EXISTS idx_pending_sync_enqueue ON pending_sync(enqueue_at);
