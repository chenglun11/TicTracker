package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Store 封装 sync.json 的读写操作，提供并发安全保证
type Store struct {
	mu      sync.RWMutex
	dataDir string

	// 内存缓存，避免频繁磁盘 IO
	cache       *SyncPayload
	cacheLoaded bool
}

func NewStore(dataDir string) *Store {
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		log.Fatalf("[store] failed to create data dir: %v", err)
	}
	return &Store{dataDir: dataDir}
}

func (s *Store) filePath() string {
	return filepath.Join(s.dataDir, "sync.json")
}

func (s *Store) backupDir() string {
	return filepath.Join(s.dataDir, "backups")
}

// Load 读取数据（读锁），返回副本
func (s *Store) Load() (*SyncPayload, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.cacheLoaded && s.cache != nil {
		return s.clonePayload(s.cache), nil
	}

	return s.loadFromDisk()
}

// Update 原子更新：读取 → 回调修改 → 写回（写锁）
func (s *Store) Update(fn func(payload *SyncPayload) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	payload, err := s.loadFromDiskUnsafe()
	if err != nil {
		return err
	}

	if err := fn(payload); err != nil {
		return err
	}

	return s.saveToDisk(payload)
}

// ReplaceRaw 用原始 JSON 替换整个文件（用于同步上传）
func (s *Store) ReplaceRaw(data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// 验证 JSON 合法性
	var check map[string]interface{}
	if err := json.Unmarshal(data, &check); err != nil {
		return fmt.Errorf("invalid json: %w", err)
	}
	if _, ok := check["lastModified"]; !ok {
		return fmt.Errorf("lastModified is required")
	}

	// 写入前备份
	s.autoBackup()

	tmpPath := s.filePath() + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := os.Rename(tmpPath, s.filePath()); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("rename: %w", err)
	}

	// 清除缓存
	s.cache = nil
	s.cacheLoaded = false

	return nil
}

// LoadRaw 返回原始 JSON 字节
func (s *Store) LoadRaw() ([]byte, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return os.ReadFile(s.filePath())
}

func (s *Store) loadFromDisk() (*SyncPayload, error) {
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
	return &payload, nil
}

// loadFromDiskUnsafe 不加锁版本，调用方需持有写锁
func (s *Store) loadFromDiskUnsafe() (*SyncPayload, error) {
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
	return &payload, nil
}

func (s *Store) saveToDisk(payload *SyncPayload) error {
	payload.LastModified = float64(time.Now().Unix())

	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}

	tmpPath := s.filePath() + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := os.Rename(tmpPath, s.filePath()); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("rename: %w", err)
	}

	// 更新缓存
	s.cache = payload
	s.cacheLoaded = true

	return nil
}

// autoBackup 自动备份（每天最多一份），调用方需持有写锁
func (s *Store) autoBackup() {
	backupDir := s.backupDir()
	if err := os.MkdirAll(backupDir, 0755); err != nil {
		log.Printf("[store] failed to create backup dir: %v", err)
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

	if err := os.WriteFile(backupFile, src, 0644); err != nil {
		log.Printf("[store] backup failed: %v", err)
		return
	}
	log.Printf("[store] auto backup created: %s", backupFile)

	// 清理 7 天前的备份
	s.cleanOldBackups(7)
}

func (s *Store) cleanOldBackups(keepDays int) {
	entries, err := os.ReadDir(s.backupDir())
	if err != nil {
		return
	}
	cutoff := time.Now().AddDate(0, 0, -keepDays)
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if info.ModTime().Before(cutoff) {
			path := filepath.Join(s.backupDir(), entry.Name())
			os.Remove(path)
			log.Printf("[store] removed old backup: %s", entry.Name())
		}
	}
}

func (s *Store) clonePayload(src *SyncPayload) *SyncPayload {
	data, err := json.Marshal(src)
	if err != nil {
		return src
	}
	var dst SyncPayload
	json.Unmarshal(data, &dst)
	return &dst
}
