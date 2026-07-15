package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// backupRetentionDays 自动备份保留天数
const backupRetentionDays = 7

// Store 封装 sync.json 的读写操作，提供并发安全保证
type Store struct {
	mu      sync.RWMutex
	dataDir string

	// 内存缓存，避免频繁磁盘 IO
	cache       *SyncPayload
	cacheLoaded bool
}

type PayloadStore interface {
	Load(ctx context.Context) (*SyncPayload, error)
	Update(ctx context.Context, fn func(payload *SyncPayload) error) error
	ReplaceRaw(ctx context.Context, data []byte) error
	LoadRaw(ctx context.Context) ([]byte, error)
}

// NewStore 创建 Store；dataDir 不存在时会以 0700 创建
func NewStore(dataDir string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create data dir %q: %w", dataDir, err)
	}
	return &Store{dataDir: dataDir}, nil
}

func (s *Store) filePath() string {
	return filepath.Join(s.dataDir, "sync.json")
}

func (s *Store) backupDir() string {
	return filepath.Join(s.dataDir, "backups")
}

// Load 读取数据（读锁），返回副本
func (s *Store) Load(ctx context.Context) (*SyncPayload, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.cacheLoaded && s.cache != nil {
		cloned, err := s.clonePayload(s.cache)
		if err != nil {
			return nil, err
		}
		return cloned, nil
	}

	return s.loadFromDiskLocked()
}

// Update 原子更新：读取 → 回调修改 → 写回（写锁）
func (s *Store) Update(ctx context.Context, fn func(payload *SyncPayload) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	payload, err := s.loadFromDiskLocked()
	if err != nil {
		return err
	}
	before, err := s.clonePayload(payload)
	if err != nil {
		return err
	}

	if err := fn(payload); err != nil {
		return err
	}
	preserveRemovedIssueTombstones(before, payload, actorFromContext(ctx))
	advanceIssueRevisions(before, payload, actorFromContext(ctx))
	advanceSyncRevision(before, payload)
	if payload.Revision > before.Revision {
		payload.LastModifiedBy = actorFromContext(ctx)
	}

	return s.saveToDiskLocked(payload)
}

func preserveRemovedIssueTombstones(before, after *SyncPayload, actor string) {
	current := make(map[string]struct{}, len(after.TrackedIssues))
	for _, issue := range after.TrackedIssues {
		current[issue.ID] = struct{}{}
	}
	now := FlexTime{Value: time.Now().UTC().Format(time.RFC3339Nano)}
	for _, old := range before.TrackedIssues {
		if _, exists := current[old.ID]; exists {
			continue
		}
		if old.DeletedAt != nil {
			after.TrackedIssues = append(after.TrackedIssues, old)
			continue
		}
		tombstone := old
		tombstone.Revision = max(old.Revision+1, 1)
		tombstone.UpdatedAt = &now
		tombstone.DeletedAt = &now
		if actor != "" {
			tombstone.UpdatedBy = &actor
		}
		after.TrackedIssues = append(after.TrackedIssues, tombstone)
	}
}

func advanceIssueRevisions(before, after *SyncPayload, actor string) {
	previous := make(map[string]TrackedIssue, len(before.TrackedIssues))
	for _, issue := range before.TrackedIssues {
		normalizeIssueMetadata(&issue)
		previous[issue.ID] = issue
	}
	for i := range after.TrackedIssues {
		issue := &after.TrackedIssues[i]
		old, existed := previous[issue.ID]
		if !existed {
			normalizeIssueMetadata(issue)
			if actor != "" && issue.UpdatedBy == nil {
				issue.UpdatedBy = &actor
			}
			continue
		}
		normalizeIssueMetadata(issue)
		if issueComparableJSON(old) == issueComparableJSON(*issue) {
			continue
		}
		if issue.Revision <= old.Revision {
			issue.Revision = old.Revision + 1
		}
		if actor != "" {
			issue.UpdatedBy = &actor
		}
	}
}

func issueComparableJSON(issue TrackedIssue) string {
	issue.Revision = 0
	issue.UpdatedBy = nil
	data, _ := json.Marshal(issue)
	return string(data)
}

// ReplaceRaw 用原始 JSON 替换整个文件（用于同步上传）
func (s *Store) ReplaceRaw(ctx context.Context, data []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

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
	before, err := s.loadFromDiskLocked()
	if err != nil {
		return err
	}
	preserveRemovedIssueTombstones(before, &payload, actorFromContext(ctx))
	advanceIssueRevisions(before, &payload, actorFromContext(ctx))
	advanceSyncRevision(before, &payload)
	if payload.Revision > before.Revision {
		payload.LastModifiedBy = actorFromContext(ctx)
	}

	// 写入前备份
	s.autoBackupLocked()

	return s.saveToDiskLocked(&payload)
}

// LoadRaw 返回原始 JSON 字节
func (s *Store) LoadRaw(ctx context.Context) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return os.ReadFile(s.filePath())
}

// loadFromDiskLocked 调用方需持有读或写锁
func (s *Store) loadFromDiskLocked() (*SyncPayload, error) {
	data, err := os.ReadFile(s.filePath())
	if err != nil {
		if os.IsNotExist(err) {
			return &SyncPayload{}, nil
		}
		return nil, err
	}
	var payload SyncPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("parse sync.json: %w", err)
	}
	normalizePayloadIssueMetadata(&payload)
	return &payload, nil
}

func (s *Store) saveToDiskLocked(payload *SyncPayload) error {
	payload.LastModified = float64(time.Now().Unix())
	normalizePayloadIssueMetadata(payload)

	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}

	if err := atomicWrite(s.filePath(), data, 0o600); err != nil {
		return err
	}

	// 更新缓存
	s.cache = payload
	s.cacheLoaded = true

	return nil
}

func advanceSyncRevision(before, after *SyncPayload) {
	if after.Revision > before.Revision {
		return
	}
	beforeData, beforeErr := syncComparableJSON(before)
	afterData, afterErr := syncComparableJSON(after)
	if beforeErr != nil || afterErr != nil || !bytes.Equal(beforeData, afterData) {
		after.Revision = before.Revision + 1
		return
	}
	after.Revision = before.Revision
}

func syncComparableJSON(payload *SyncPayload) ([]byte, error) {
	data, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		return nil, err
	}
	delete(object, "revision")
	delete(object, "lastModified")
	delete(object, "lastModifiedBy")
	if config, ok := object["feishuBotConfig"].(map[string]any); ok {
		// 这些字段由服务端定时任务维护，不属于用户协作内容。忽略它们可
		// 避免一次日报发送让正在编辑 Bug 的客户端产生无意义冲突。
		delete(config, "lastSentTimes")
		delete(config, "lastSentDateTime")
		delete(config, "issueMonthlyReportLastSentMonth")
	}
	return json.Marshal(object)
}

// autoBackupLocked 自动备份（每天最多一份），调用方需持有写锁
func (s *Store) autoBackupLocked() {
	backupDir := s.backupDir()
	if err := os.MkdirAll(backupDir, 0o700); err != nil {
		slog.Warn("create backup dir failed", "err", err)
		return
	}

	today := time.Now().Format("2006-01-02")
	backupFile := filepath.Join(backupDir, fmt.Sprintf("sync_%s.json", today))

	// 今天已有备份则跳过
	if _, err := os.Stat(backupFile); err == nil {
		return
	}

	src, err := os.ReadFile(s.filePath())
	if err != nil {
		return
	}

	if err := atomicWrite(backupFile, src, 0o600); err != nil {
		slog.Warn("backup failed", "err", err)
		return
	}
	slog.Info("auto backup created", "file", backupFile)

	s.cleanOldBackupsLocked(backupRetentionDays)
}

// cleanOldBackupsLocked 按文件名 sync_YYYY-MM-DD.json 解析日期清理旧备份
func (s *Store) cleanOldBackupsLocked(keepDays int) {
	entries, err := os.ReadDir(s.backupDir())
	if err != nil {
		return
	}
	cutoff := time.Now().AddDate(0, 0, -keepDays)
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "sync_") || !strings.HasSuffix(name, ".json") {
			continue
		}
		dateStr := strings.TrimSuffix(strings.TrimPrefix(name, "sync_"), ".json")
		t, err := time.Parse("2006-01-02", dateStr)
		if err != nil {
			continue
		}
		if t.Before(cutoff) {
			path := filepath.Join(s.backupDir(), name)
			if rmErr := os.Remove(path); rmErr != nil {
				slog.Warn("remove old backup failed", "file", name, "err", rmErr)
				continue
			}
			slog.Info("removed old backup", "file", name)
		}
	}
}

// clonePayload 通过 JSON 往返深拷贝 payload（失败时返回错误而非静默回退）
func (s *Store) clonePayload(src *SyncPayload) (*SyncPayload, error) {
	data, err := json.Marshal(src)
	if err != nil {
		return nil, fmt.Errorf("clone marshal: %w", err)
	}
	var dst SyncPayload
	if err := json.Unmarshal(data, &dst); err != nil {
		return nil, fmt.Errorf("clone unmarshal: %w", err)
	}
	return &dst, nil
}

// atomicWrite 通过 temp+rename 原子写入文件，并以指定权限创建
func atomicWrite(path string, data []byte, perm os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("rename: %w", err)
	}
	return nil
}
