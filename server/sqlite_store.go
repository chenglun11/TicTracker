package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type SQLiteStore struct {
	mu        sync.Mutex
	dbPath    string
	sqliteBin string
	dataDir   string
}

func NewSQLiteStore(ctx context.Context, cfg *Config) (*SQLiteStore, error) {
	dataDir := cfg.DataDir
	if dataDir == "" {
		dataDir = "./data"
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create data dir %q: %w", dataDir, err)
	}

	dbPath := cfg.DatabasePath
	if dbPath == "" {
		dbPath = filepath.Join(dataDir, "tictacker.sqlite3")
	}
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o700); err != nil {
		return nil, fmt.Errorf("create database directory: %w", err)
	}
	sqliteBin := cfg.SQLiteBin
	if sqliteBin == "" {
		sqliteBin = "sqlite3"
	}
	if _, err := exec.LookPath(sqliteBin); err != nil {
		return nil, fmt.Errorf("sqlite binary %q not found: %w", sqliteBin, err)
	}

	store := &SQLiteStore{
		dbPath:    dbPath,
		sqliteBin: sqliteBin,
		dataDir:   dataDir,
	}
	if err := store.backupSQLiteBeforeMigration(ctx); err != nil {
		return nil, err
	}
	if err := store.migrate(ctx); err != nil {
		return nil, err
	}
	if err := os.Chmod(dbPath, 0o600); err != nil {
		slog.Warn("sqlite database chmod failed", "path", dbPath, "err", err)
	}
	if err := store.ensureDefaultWorkspace(ctx, cfg); err != nil {
		return nil, err
	}
	if err := store.importLegacySyncFile(ctx); err != nil {
		return nil, err
	}
	return store, nil
}

func (s *SQLiteStore) backupSQLiteBeforeMigration(ctx context.Context) error {
	info, err := os.Stat(s.dbPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("stat sqlite database before migration: %w", err)
	}
	if info.Size() == 0 {
		return nil
	}
	backupDir := filepath.Join(s.dataDir, "backups", "migrations")
	if err := os.MkdirAll(backupDir, 0o700); err != nil {
		return fmt.Errorf("create migration backup directory: %w", err)
	}
	backupPath := filepath.Join(backupDir, "tictacker_pre_migration_"+time.Now().Format("20060102")+".sqlite3")
	if _, err := os.Stat(backupPath); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("stat migration backup: %w", err)
	}
	command := exec.CommandContext(ctx, s.sqliteBin, s.dbPath, "VACUUM INTO "+sqlQuote(backupPath)+";")
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("backup sqlite before migration: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if err := os.Chmod(backupPath, 0o600); err != nil {
		return fmt.Errorf("protect migration backup: %w", err)
	}
	entries, _ := os.ReadDir(backupDir)
	cutoff := time.Now().AddDate(0, 0, -30)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "tictacker_pre_migration_") {
			continue
		}
		entryInfo, infoErr := entry.Info()
		if infoErr == nil && entryInfo.ModTime().Before(cutoff) {
			_ = os.Remove(filepath.Join(backupDir, entry.Name()))
		}
	}
	return nil
}

func (s *SQLiteStore) ResolveWorkspace(ctx context.Context, capability, token string) (*Workspace, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, fmt.Errorf("empty token")
	}
	where := "sync_token = " + sqlQuote(token)
	if capability == "web" {
		where = "web_token = " + sqlQuote(token)
	}
	out, err := s.query(ctx, "SELECT id || char(9) || name || char(9) || coalesce(sync_token,'') || char(9) || coalesce(web_token,'') FROM workspaces WHERE "+where+" LIMIT 1;")
	if err != nil {
		return nil, err
	}
	line := strings.TrimSpace(string(out))
	if line == "" {
		return nil, fmt.Errorf("workspace not found")
	}
	parts := strings.Split(line, "\t")
	for len(parts) < 4 {
		parts = append(parts, "")
	}
	return &Workspace{ID: parts[0], Name: parts[1], SyncToken: parts[2], WebToken: parts[3]}, nil
}

func (s *SQLiteStore) ResolveWorkspaceByID(ctx context.Context, workspaceID string) (*Workspace, error) {
	workspaceID = strings.TrimSpace(workspaceID)
	if workspaceID == "" {
		return nil, fmt.Errorf("workspace id is required")
	}
	out, err := s.query(ctx, "SELECT id || char(9) || name || char(9) || coalesce(sync_token,'') || char(9) || coalesce(web_token,'') FROM workspaces WHERE id="+sqlQuote(workspaceID)+" LIMIT 1;")
	if err != nil {
		return nil, err
	}
	parts := strings.Split(strings.TrimSpace(string(out)), "\t")
	if len(parts) < 4 || parts[0] == "" {
		return nil, fmt.Errorf("workspace not found")
	}
	return &Workspace{ID: parts[0], Name: parts[1], SyncToken: parts[2], WebToken: parts[3]}, nil
}

func (s *SQLiteStore) WorkspaceIDs(ctx context.Context) ([]string, error) {
	out, err := s.query(ctx, "SELECT id FROM workspaces ORDER BY created_at;")
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	ids := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" {
			ids = append(ids, line)
		}
	}
	if len(ids) == 0 {
		ids = append(ids, defaultWorkspaceID)
	}
	return ids, nil
}

func (s *SQLiteStore) RotateWorkspaceSyncToken(ctx context.Context, workspaceID, token string) error {
	workspaceID = strings.TrimSpace(workspaceID)
	token = strings.TrimSpace(token)
	if workspaceID == "" || token == "" {
		return fmt.Errorf("workspace id and sync token are required")
	}
	_, err := s.exec(ctx, "UPDATE workspaces SET sync_token="+sqlQuote(token)+", updated_at="+sqlQuote(time.Now().Format("2006-01-02 15:04:05"))+" WHERE id="+sqlQuote(workspaceID)+";")
	return err
}

func (s *SQLiteStore) LatestCollaborationCursor(ctx context.Context, workspaceID string) (int64, error) {
	out, err := s.query(ctx, "SELECT coalesce(max(cursor),0) FROM collaboration_events WHERE workspace_id="+sqlQuote(workspaceID)+";")
	if err != nil {
		return 0, err
	}
	value, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return 0, nil
	}
	return value, nil
}

func (s *SQLiteStore) Load(ctx context.Context) (*SyncPayload, error) {
	workspaceID := workspaceIDFromContext(ctx)
	data, err := s.loadRawForWorkspace(ctx, workspaceID)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return &SyncPayload{}, nil
	}
	var payload SyncPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("parse workspace payload: %w", err)
	}
	normalizePayloadIssueMetadata(&payload)
	return &payload, nil
}

func (s *SQLiteStore) LoadRaw(ctx context.Context) ([]byte, error) {
	workspaceID := workspaceIDFromContext(ctx)
	data, err := s.loadRawForWorkspace(ctx, workspaceID)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, os.ErrNotExist
	}
	return data, nil
}

func (s *SQLiteStore) ReplaceRaw(ctx context.Context, data []byte) error {
	if !json.Valid(data) {
		return fmt.Errorf("invalid json")
	}
	var payload SyncPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return fmt.Errorf("invalid json: %w", err)
	}
	if payload.LastModified == 0 {
		return fmt.Errorf("lastModified is required")
	}
	workspaceID := workspaceIDFromContext(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	before, err := s.loadPayloadUnlocked(ctx, workspaceID)
	if err != nil {
		return err
	}
	preserveRemovedIssueTombstones(before, &payload, actorFromContext(ctx))
	advanceIssueRevisions(before, &payload, actorFromContext(ctx))
	events := buildIssueEvents(before, &payload, actorFromContext(ctx))
	return s.savePayloadAndEventsUnlocked(ctx, workspaceID, &payload, events)
}

func (s *SQLiteStore) Update(ctx context.Context, fn func(payload *SyncPayload) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	workspaceID := workspaceIDFromContext(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	if operationID := operationIDFromContext(ctx); operationID != "" {
		out, checkErr := s.query(ctx, "SELECT 1 FROM collaboration_events WHERE workspace_id="+sqlQuote(workspaceID)+" AND operation_id="+sqlQuote(operationID)+" LIMIT 1;")
		if checkErr != nil {
			return checkErr
		}
		if strings.TrimSpace(string(out)) == "1" {
			return errOperationAlreadyApplied
		}
	}

	payload, err := s.loadPayloadUnlocked(ctx, workspaceID)
	if err != nil {
		return err
	}
	beforeData, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("clone workspace payload: %w", err)
	}
	var before SyncPayload
	if err := json.Unmarshal(beforeData, &before); err != nil {
		return fmt.Errorf("clone workspace payload: %w", err)
	}
	if err := fn(payload); err != nil {
		return err
	}
	preserveRemovedIssueTombstones(&before, payload, actorFromContext(ctx))
	advanceIssueRevisions(&before, payload, actorFromContext(ctx))
	advanceSyncRevision(&before, payload)
	if payload.Revision > before.Revision {
		payload.LastModifiedBy = actorFromContext(ctx)
	}
	events := buildIssueEvents(&before, payload, actorFromContext(ctx))
	for i := range events {
		events[i].OperationID = operationIDFromContext(ctx)
	}
	return s.savePayloadAndEventsUnlocked(ctx, workspaceID, payload, events)
}

func (s *SQLiteStore) SaveFeishuRun(ctx context.Context, workspaceID, slotKey, dateKey, sentAt string, success bool, message string) error {
	successInt := 0
	if success {
		successInt = 1
	}
	sql := fmt.Sprintf(`INSERT INTO feishu_send_runs(workspace_id, slot_key, date_key, sent_at, success, message)
VALUES(%s,%s,%s,%s,%d,%s)
ON CONFLICT(workspace_id, slot_key, date_key) DO UPDATE SET
sent_at=excluded.sent_at, success=excluded.success, message=excluded.message;`,
		sqlQuote(workspaceID), sqlQuote(slotKey), sqlQuote(dateKey), sqlQuote(sentAt), successInt, sqlQuote(message))
	_, err := s.exec(ctx, sql)
	return err
}

func (s *SQLiteStore) HasSuccessfulFeishuRun(ctx context.Context, workspaceID, slotKey, dateKey string) (bool, error) {
	out, err := s.query(ctx, "SELECT 1 FROM feishu_send_runs WHERE workspace_id = "+sqlQuote(workspaceID)+" AND slot_key = "+sqlQuote(slotKey)+" AND date_key = "+sqlQuote(dateKey)+" AND success = 1 LIMIT 1;")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(out)) == "1", nil
}

func (s *SQLiteStore) FindWorkspaceIDForIssue(ctx context.Context, issueID string) (string, error) {
	out, err := s.query(ctx, "SELECT workspace_id FROM issues WHERE id = "+sqlQuote(issueID)+" ORDER BY updated_at DESC LIMIT 1;")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func (s *SQLiteStore) FindWorkspaceIDForFeishuTask(ctx context.Context, taskGUID string) (string, error) {
	out, err := s.query(ctx, "SELECT workspace_id FROM issues WHERE feishu_task_guid = "+sqlQuote(taskGUID)+" ORDER BY updated_at DESC LIMIT 1;")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func (s *SQLiteStore) loadRawForWorkspace(ctx context.Context, workspaceID string) ([]byte, error) {
	out, err := s.query(ctx, "SELECT payload_json FROM workspace_payloads WHERE workspace_id = "+sqlQuote(workspaceID)+" LIMIT 1;")
	if err != nil {
		return nil, err
	}
	text := strings.TrimRight(string(out), "\r\n")
	if text == "" {
		return nil, nil
	}
	return []byte(text), nil
}

func (s *SQLiteStore) loadPayloadUnlocked(ctx context.Context, workspaceID string) (*SyncPayload, error) {
	data, err := s.loadRawForWorkspace(ctx, workspaceID)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return &SyncPayload{}, nil
	}
	var payload SyncPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("parse workspace payload: %w", err)
	}
	return &payload, nil
}

func (s *SQLiteStore) savePayload(ctx context.Context, workspaceID string, payload *SyncPayload) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.savePayloadUnlocked(ctx, workspaceID, payload)
}

func (s *SQLiteStore) savePayloadUnlocked(ctx context.Context, workspaceID string, payload *SyncPayload) error {
	return s.savePayloadAndEventsUnlocked(ctx, workspaceID, payload, nil)
}

func (s *SQLiteStore) savePayloadAndEventsUnlocked(ctx context.Context, workspaceID string, payload *SyncPayload, events []CollaborationEvent) error {
	if workspaceID == "" {
		workspaceID = defaultWorkspaceID
	}
	payload.LastModified = float64(time.Now().Unix())
	normalizePayloadIssueMetadata(payload)
	data, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal workspace payload: %w", err)
	}
	sql := s.normalizedSQL(workspaceID, payload, string(data), events)
	_, err = s.exec(ctx, sql)
	return err
}

func (s *SQLiteStore) migrate(ctx context.Context) error {
	sql := `
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS workspaces(
	id TEXT PRIMARY KEY,
	name TEXT NOT NULL,
	sync_token TEXT UNIQUE,
	web_token TEXT UNIQUE,
	config_json TEXT,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS users(
	workspace_id TEXT NOT NULL,
	id TEXT NOT NULL,
	name TEXT NOT NULL,
	role TEXT NOT NULL DEFAULT 'member',
	disabled_at TEXT,
	created_at TEXT NOT NULL,
	updated_at TEXT,
	PRIMARY KEY(workspace_id, id)
);
CREATE TABLE IF NOT EXISTS web_accounts(
	workspace_id TEXT NOT NULL,
	username TEXT NOT NULL,
	password_salt TEXT NOT NULL,
	password_hash TEXT NOT NULL,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL,
	PRIMARY KEY(workspace_id, username)
);
CREATE TABLE IF NOT EXISTS web_sessions(
	token TEXT PRIMARY KEY,
	workspace_id TEXT NOT NULL,
	username TEXT NOT NULL,
	expires_at TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS workspace_payloads(
	workspace_id TEXT PRIMARY KEY,
	payload_json TEXT NOT NULL,
	last_modified REAL NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS issues(
	workspace_id TEXT NOT NULL,
	id TEXT NOT NULL,
	issue_number INTEGER,
	type TEXT,
	title TEXT,
	date_key TEXT,
	created_at TEXT,
	updated_at TEXT,
	revision INTEGER NOT NULL DEFAULT 1,
	updated_by TEXT,
	deleted_at TEXT,
	diary_badge TEXT,
	status TEXT,
	source TEXT,
	assignee TEXT,
	jira_key TEXT,
	ticket_url TEXT,
	department TEXT,
	resolved_at TEXT,
	has_dev_activity INTEGER NOT NULL DEFAULT 0,
	is_escalated INTEGER NOT NULL DEFAULT 0,
	feishu_task_guid TEXT,
	feishu_task_summary TEXT,
	feishu_task_completed_at TEXT,
	linear_issue_id TEXT,
	linear_key TEXT,
	linear_url TEXT,
	linear_project_id TEXT,
	linear_project_name TEXT,
	linear_assignee TEXT,
	reporter_id TEXT,
	reporter_name TEXT,
	reported_at TEXT,
	raw_json TEXT NOT NULL,
	PRIMARY KEY(workspace_id, id)
);
CREATE TABLE IF NOT EXISTS issue_comments(
	workspace_id TEXT NOT NULL,
	issue_id TEXT NOT NULL,
	id TEXT NOT NULL,
	text TEXT NOT NULL,
	created_at TEXT,
	jira_comment_id TEXT,
	PRIMARY KEY(workspace_id, issue_id, id)
);
CREATE TABLE IF NOT EXISTS issue_tags(
	workspace_id TEXT NOT NULL,
	issue_id TEXT NOT NULL,
	tag TEXT NOT NULL,
	PRIMARY KEY(workspace_id, issue_id, tag)
);
CREATE TABLE IF NOT EXISTS support_records(
	workspace_id TEXT NOT NULL,
	date_key TEXT NOT NULL,
	department TEXT NOT NULL,
	count INTEGER NOT NULL,
	PRIMARY KEY(workspace_id, date_key, department)
);
CREATE TABLE IF NOT EXISTS daily_notes(
	workspace_id TEXT NOT NULL,
	date_key TEXT NOT NULL,
	note TEXT NOT NULL,
	PRIMARY KEY(workspace_id, date_key)
);
CREATE TABLE IF NOT EXISTS external_bindings(
	workspace_id TEXT NOT NULL,
	issue_id TEXT NOT NULL,
	provider TEXT NOT NULL,
	external_id TEXT NOT NULL,
	external_key TEXT,
	url TEXT,
	raw_json TEXT,
	PRIMARY KEY(workspace_id, issue_id, provider, external_id)
);
CREATE TABLE IF NOT EXISTS feishu_configs(
	workspace_id TEXT PRIMARY KEY,
	config_json TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS feishu_send_runs(
	workspace_id TEXT NOT NULL,
	slot_key TEXT NOT NULL,
	date_key TEXT NOT NULL,
	sent_at TEXT NOT NULL,
	success INTEGER NOT NULL,
	message TEXT,
	PRIMARY KEY(workspace_id, slot_key, date_key)
);
CREATE TABLE IF NOT EXISTS collaboration_events(
	cursor INTEGER PRIMARY KEY AUTOINCREMENT,
	workspace_id TEXT NOT NULL,
	event_type TEXT NOT NULL,
	entity_id TEXT NOT NULL,
	entity_revision INTEGER NOT NULL,
	payload_json TEXT NOT NULL,
	actor TEXT,
	created_at TEXT NOT NULL,
	operation_id TEXT
);
CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_issues_workspace_status ON issues(workspace_id, status);
CREATE INDEX IF NOT EXISTS idx_issues_workspace_date ON issues(workspace_id, date_key);
CREATE INDEX IF NOT EXISTS idx_issues_reporter ON issues(workspace_id, reporter_id, reporter_name);
CREATE INDEX IF NOT EXISTS idx_collaboration_events_workspace_cursor ON collaboration_events(workspace_id, cursor);
INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, datetime('now'));
COMMIT;
`
	if _, err := s.exec(ctx, sql); err != nil {
		return err
	}
	for _, column := range []struct {
		name       string
		definition string
	}{
		{name: "revision", definition: "INTEGER NOT NULL DEFAULT 1"},
		{name: "updated_by", definition: "TEXT"},
		{name: "deleted_at", definition: "TEXT"},
	} {
		if err := s.ensureSQLiteColumn(ctx, "issues", column.name, column.definition); err != nil {
			return err
		}
	}
	if err := s.ensureSQLiteColumn(ctx, "collaboration_events", "operation_id", "TEXT"); err != nil {
		return err
	}
	if _, err := s.exec(ctx, "CREATE UNIQUE INDEX IF NOT EXISTS idx_collaboration_events_operation ON collaboration_events(workspace_id, operation_id) WHERE operation_id IS NOT NULL AND operation_id <> '';\n"); err != nil {
		return err
	}
	for _, column := range []struct {
		name       string
		definition string
	}{
		{name: "disabled_at", definition: "TEXT"},
		{name: "updated_at", definition: "TEXT"},
	} {
		if err := s.ensureSQLiteColumn(ctx, "users", column.name, column.definition); err != nil {
			return err
		}
	}
	// Existing deployments predate RBAC. Preserve access by materializing their
	// accounts as admins; newly created accounts always receive an explicit role.
	if _, err := s.exec(ctx, `INSERT OR IGNORE INTO users(workspace_id,id,name,role,created_at,updated_at)
SELECT workspace_id,username,username,'admin',created_at,updated_at FROM web_accounts;
`); err != nil {
		return err
	}
	_, err := s.exec(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(2, datetime('now')); INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(3, datetime('now'));\n")
	return err
}

func (s *SQLiteStore) ensureSQLiteColumn(ctx context.Context, table, column, definition string) error {
	out, err := s.query(ctx, "SELECT count(*) FROM pragma_table_info("+sqlQuote(table)+") WHERE name = "+sqlQuote(column)+";")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(out)) == "1" {
		return nil
	}
	_, err = s.exec(ctx, "ALTER TABLE "+table+" ADD COLUMN "+column+" "+definition+";\n")
	return err
}

func (s *SQLiteStore) ensureDefaultWorkspace(ctx context.Context, cfg *Config) error {
	now := time.Now().Format("2006-01-02 15:04:05")
	name := cfg.DefaultWorkspaceName
	if name == "" {
		name = "Default Workspace"
	}
	sql := fmt.Sprintf(`INSERT INTO workspaces(id, name, sync_token, web_token, config_json, created_at, updated_at)
VALUES(%s,%s,%s,%s,%s,%s,%s)
ON CONFLICT(id) DO UPDATE SET
name=excluded.name,
sync_token=CASE WHEN workspaces.sync_token IS NULL OR workspaces.sync_token='' THEN excluded.sync_token ELSE workspaces.sync_token END,
web_token=CASE WHEN workspaces.web_token IS NULL OR workspaces.web_token='' THEN excluded.web_token ELSE workspaces.web_token END,
updated_at=excluded.updated_at;`,
		sqlQuote(defaultWorkspaceID), sqlQuote(name), sqlQuote(cfg.SyncAccessToken()), sqlQuote(cfg.WebAccessToken()), sqlQuote("{}"), sqlQuote(now), sqlQuote(now))
	_, err := s.exec(ctx, sql)
	return err
}

func (s *SQLiteStore) importLegacySyncFile(ctx context.Context) error {
	legacyPath := filepath.Join(s.dataDir, "sync.json")
	data, err := os.ReadFile(legacyPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	markerKey := "legacy_import:" + legacyPath
	hash := fmt.Sprintf("%x", sha256.Sum256(data))
	out, err := s.query(ctx, "SELECT value FROM metadata WHERE key = "+sqlQuote(markerKey)+" LIMIT 1;")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(out)) == hash {
		return nil
	}
	var payload SyncPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return fmt.Errorf("parse legacy sync.json: %w", err)
	}
	if err := s.savePayload(ctx, defaultWorkspaceID, &payload); err != nil {
		return err
	}
	backupDir := filepath.Join(s.dataDir, "backups")
	if err := os.MkdirAll(backupDir, 0o700); err == nil {
		backupPath := filepath.Join(backupDir, "sync_legacy_import_"+time.Now().Format("20060102_150405")+".json")
		if writeErr := os.WriteFile(backupPath, data, 0o600); writeErr != nil {
			slog.Warn("legacy sync backup failed", "err", writeErr)
		}
	}
	_, err = s.exec(ctx, "INSERT OR REPLACE INTO metadata(key, value) VALUES("+sqlQuote(markerKey)+", "+sqlQuote(hash)+");")
	if err == nil {
		slog.Info("legacy sync.json imported into sqlite", "path", legacyPath)
	}
	return err
}

func (s *SQLiteStore) normalizedSQL(workspaceID string, payload *SyncPayload, payloadJSON string, events []CollaborationEvent) string {
	now := time.Now().Format("2006-01-02 15:04:05")
	var b strings.Builder
	b.WriteString("BEGIN IMMEDIATE;\n")
	b.WriteString("INSERT OR IGNORE INTO workspaces(id, name, created_at, updated_at) VALUES(" + sqlQuote(workspaceID) + ", " + sqlQuote(workspaceID) + ", " + sqlQuote(now) + ", " + sqlQuote(now) + ");\n")
	b.WriteString("UPDATE workspaces SET updated_at = " + sqlQuote(now) + " WHERE id = " + sqlQuote(workspaceID) + ";\n")
	b.WriteString("DELETE FROM issue_comments WHERE workspace_id = " + sqlQuote(workspaceID) + ";\n")
	b.WriteString("DELETE FROM issue_tags WHERE workspace_id = " + sqlQuote(workspaceID) + ";\n")
	b.WriteString("DELETE FROM external_bindings WHERE workspace_id = " + sqlQuote(workspaceID) + ";\n")
	b.WriteString("DELETE FROM support_records WHERE workspace_id = " + sqlQuote(workspaceID) + ";\n")
	b.WriteString("DELETE FROM daily_notes WHERE workspace_id = " + sqlQuote(workspaceID) + ";\n")
	b.WriteString("DELETE FROM feishu_configs WHERE workspace_id = " + sqlQuote(workspaceID) + ";\n")
	b.WriteString("DELETE FROM issues WHERE workspace_id = " + sqlQuote(workspaceID) + ";\n")

	b.WriteString("INSERT OR REPLACE INTO workspace_payloads(workspace_id, payload_json, last_modified, updated_at) VALUES(")
	b.WriteString(sqlQuote(workspaceID) + "," + sqlQuote(payloadJSON) + "," + strconv.FormatFloat(payload.LastModified, 'f', -1, 64) + "," + sqlQuote(now) + ");\n")

	for dateKey, departments := range payload.Records {
		for department, count := range departments {
			b.WriteString(fmt.Sprintf("INSERT OR REPLACE INTO support_records(workspace_id, date_key, department, count) VALUES(%s,%s,%s,%d);\n",
				sqlQuote(workspaceID), sqlQuote(dateKey), sqlQuote(department), count))
		}
	}
	for dateKey, note := range payload.DailyNotes {
		b.WriteString("INSERT OR REPLACE INTO daily_notes(workspace_id, date_key, note) VALUES(" + sqlQuote(workspaceID) + "," + sqlQuote(dateKey) + "," + sqlQuote(note) + ");\n")
	}
	if payload.FeishuBotConfig != nil {
		if cfgJSON, err := json.Marshal(payload.FeishuBotConfig); err == nil {
			b.WriteString("INSERT OR REPLACE INTO feishu_configs(workspace_id, config_json, updated_at) VALUES(" + sqlQuote(workspaceID) + "," + sqlQuote(string(cfgJSON)) + "," + sqlQuote(now) + ");\n")
		}
	}

	for _, issue := range payload.TrackedIssues {
		raw, _ := json.Marshal(issue)
		b.WriteString("INSERT OR REPLACE INTO issues(")
		b.WriteString("workspace_id,id,issue_number,type,title,date_key,created_at,updated_at,revision,updated_by,deleted_at,diary_badge,status,source,assignee,jira_key,ticket_url,department,resolved_at,has_dev_activity,is_escalated,feishu_task_guid,feishu_task_summary,feishu_task_completed_at,linear_issue_id,linear_key,linear_url,linear_project_id,linear_project_name,linear_assignee,reporter_id,reporter_name,reported_at,raw_json")
		b.WriteString(") VALUES(")
		values := []string{
			sqlQuote(workspaceID),
			sqlQuote(issue.ID),
			strconv.Itoa(issue.IssueNumber),
			sqlQuote(issue.Type),
			sqlQuote(issue.Title),
			sqlQuote(issue.DateKey),
			sqlQuote(issue.CreatedAt.Value),
			sqlQuote(flexPtrValue(issue.UpdatedAt)),
			strconv.FormatInt(issue.Revision, 10),
			sqlQuote(ptrValue(issue.UpdatedBy)),
			sqlQuote(flexPtrValue(issue.DeletedAt)),
			sqlQuote(issue.DiaryBadge),
			sqlQuote(issue.Status),
			sqlQuote(issue.Source),
			sqlQuote(ptrValue(issue.Assignee)),
			sqlQuote(ptrValue(issue.JiraKey)),
			sqlQuote(ptrValue(issue.TicketURL)),
			sqlQuote(ptrValue(issue.Department)),
			sqlQuote(flexPtrValue(issue.ResolvedAt)),
			boolSQL(issue.HasDevActivity),
			boolSQL(issue.IsEscalated),
			sqlQuote(ptrValue(issue.FeishuTaskGUID)),
			sqlQuote(ptrValue(issue.FeishuTaskSummary)),
			sqlQuote(ptrValue(issue.FeishuTaskCompletedAt)),
			sqlQuote(ptrValue(issue.LinearIssueID)),
			sqlQuote(ptrValue(issue.LinearKey)),
			sqlQuote(ptrValue(issue.LinearURL)),
			sqlQuote(ptrValue(issue.LinearProjectID)),
			sqlQuote(ptrValue(issue.LinearProjectName)),
			sqlQuote(ptrValue(issue.LinearAssignee)),
			sqlQuote(ptrValue(issue.ReporterID)),
			sqlQuote(ptrValue(issue.ReporterName)),
			sqlQuote(flexPtrValue(issue.ReportedAt)),
			sqlQuote(string(raw)),
		}
		b.WriteString(strings.Join(values, ","))
		b.WriteString(");\n")

		for _, comment := range issue.Comments {
			b.WriteString("INSERT OR REPLACE INTO issue_comments(workspace_id, issue_id, id, text, created_at, jira_comment_id) VALUES(")
			b.WriteString(strings.Join([]string{
				sqlQuote(workspaceID),
				sqlQuote(issue.ID),
				sqlQuote(comment.ID),
				sqlQuote(comment.Text),
				sqlQuote(comment.CreatedAt.Value),
				sqlQuote(ptrValue(comment.JiraCommentID)),
			}, ","))
			b.WriteString(");\n")
		}
		for _, tag := range normalizeIssueTags(issue.IssueTags) {
			b.WriteString("INSERT OR IGNORE INTO issue_tags(workspace_id, issue_id, tag) VALUES(" + sqlQuote(workspaceID) + "," + sqlQuote(issue.ID) + "," + sqlQuote(tag) + ");\n")
		}
		for _, binding := range externalBindingsForIssue(issue) {
			b.WriteString("INSERT OR REPLACE INTO external_bindings(workspace_id, issue_id, provider, external_id, external_key, url, raw_json) VALUES(")
			b.WriteString(strings.Join([]string{
				sqlQuote(workspaceID),
				sqlQuote(issue.ID),
				sqlQuote(binding.Provider),
				sqlQuote(binding.ExternalID),
				sqlQuote(binding.ExternalKey),
				sqlQuote(binding.URL),
				sqlQuote(binding.RawJSON),
			}, ","))
			b.WriteString(");\n")
		}
	}
	for _, event := range events {
		b.WriteString("INSERT INTO collaboration_events(workspace_id,event_type,entity_id,entity_revision,payload_json,actor,created_at,operation_id) VALUES(")
		b.WriteString(strings.Join([]string{
			sqlQuote(workspaceID),
			sqlQuote(event.Type),
			sqlQuote(event.EntityID),
			strconv.FormatInt(event.EntityRevision, 10),
			sqlQuote(string(event.Payload)),
			sqlQuote(event.Actor),
			sqlQuote(event.CreatedAt),
			sqlQuote(event.OperationID),
		}, ","))
		b.WriteString(");\n")
	}
	b.WriteString("COMMIT;\n")
	return b.String()
}

func (s *SQLiteStore) exec(ctx context.Context, sql string) ([]byte, error) {
	return s.run(ctx, sql)
}

func (s *SQLiteStore) query(ctx context.Context, sql string) ([]byte, error) {
	return s.run(ctx, ".headers off\n.mode list\n.separator '\t'\n"+sql)
}

func (s *SQLiteStore) run(ctx context.Context, sql string) ([]byte, error) {
	const attempts = 3
	sql = ".timeout 5000\nPRAGMA foreign_keys=ON;\n" + sql
	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		cmd := exec.CommandContext(ctx, s.sqliteBin, "-batch", s.dbPath)
		cmd.Stdin = strings.NewReader(sql)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		err := cmd.Run()
		message := strings.TrimSpace(stderr.String())
		if err == nil {
			if message != "" {
				slog.Debug("sqlite stderr", "message", message)
			}
			return stdout.Bytes(), nil
		}
		lastErr = fmt.Errorf("sqlite: %w: %s", err, message)
		lower := strings.ToLower(message)
		if !strings.Contains(lower, "database is locked") && !strings.Contains(lower, "database is busy") {
			return nil, lastErr
		}
		if attempt+1 < attempts {
			delay := time.Duration(50*(1<<attempt)) * time.Millisecond
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(delay):
			}
		}
	}
	return nil, lastErr
}

type externalBindingRow struct {
	Provider    string
	ExternalID  string
	ExternalKey string
	URL         string
	RawJSON     string
}

func externalBindingsForIssue(issue TrackedIssue) []externalBindingRow {
	out := make([]externalBindingRow, 0, 4)
	add := func(provider, id, key, url string, raw any) {
		if strings.TrimSpace(id) == "" && strings.TrimSpace(key) == "" && strings.TrimSpace(url) == "" {
			return
		}
		if id == "" {
			id = key
		}
		rawJSON := ""
		if raw != nil {
			if data, err := json.Marshal(raw); err == nil {
				rawJSON = string(data)
			}
		}
		out = append(out, externalBindingRow{Provider: provider, ExternalID: id, ExternalKey: key, URL: url, RawJSON: rawJSON})
	}
	add("jira", ptrValue(issue.JiraKey), ptrValue(issue.JiraKey), ptrValue(issue.TicketURL), map[string]string{
		"jiraKey": ptrValue(issue.JiraKey), "ticketURL": ptrValue(issue.TicketURL),
	})
	add("linear", ptrValue(issue.LinearIssueID), ptrValue(issue.LinearKey), ptrValue(issue.LinearURL), map[string]string{
		"linearIssueId": ptrValue(issue.LinearIssueID), "linearKey": ptrValue(issue.LinearKey), "linearUrl": ptrValue(issue.LinearURL),
		"linearProjectId": ptrValue(issue.LinearProjectID), "linearProjectName": ptrValue(issue.LinearProjectName),
	})
	add("feishu_task", ptrValue(issue.FeishuTaskGUID), ptrValue(issue.FeishuTaskGUID), "", map[string]any{
		"feishuTaskGuid": ptrValue(issue.FeishuTaskGUID), "tasklists": issue.FeishuTasklistGUIDs, "assignees": issue.FeishuTaskAssigneeIDs,
	})
	return out
}

func sqlQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func boolSQL(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

func ptrValue(v *string) string {
	if v == nil {
		return ""
	}
	return *v
}

func flexPtrValue(v *FlexTime) string {
	if v == nil {
		return ""
	}
	return v.Value
}
