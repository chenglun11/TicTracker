package main

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

type Scheduler struct {
	cfg        *Config
	store      PayloadStore
	mu         sync.Mutex
	lastSent   map[string]string    // "workspace:HH:MM" -> "YYYY-MM-DD"
	lastFailed map[string]time.Time // "workspace:HH:MM" -> last failed attempt time
}

func NewScheduler(cfg *Config, store PayloadStore) *Scheduler {
	return &Scheduler{
		cfg:        cfg,
		store:      store,
		lastSent:   make(map[string]string),
		lastFailed: make(map[string]time.Time),
	}
}

const schedulerFailureCooldown = 10 * time.Minute

// Run 启动调度器；ctx 取消时优雅退出
func (s *Scheduler) Run(ctx context.Context) {
	slog.Info("scheduler started", "interval_sec", 30)
	s.primeLastSent(ctx) // 恢复启动前的发送记录，避免重启后重复发送

	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	// 立即检查一次再等
	s.check(ctx)
	for {
		select {
		case <-ctx.Done():
			slog.Info("scheduler stopped")
			return
		case <-ticker.C:
			s.check(ctx)
		}
	}
}

// primeLastSent 启动时从持久化的 LastSentTimes 恢复，避免 crash 重启后重复发送
func (s *Scheduler) primeLastSent(ctx context.Context) {
	for _, workspaceID := range s.workspaceIDs(ctx) {
		wctx := withWorkspaceID(ctx, workspaceID)
		payload, err := s.store.Load(wctx)
		if err != nil || payload.FeishuBotConfig == nil {
			continue
		}
		s.mu.Lock()
		for key, date := range payload.FeishuBotConfig.LastSentTimes {
			s.lastSent[s.schedulerKey(workspaceID, key)] = date
		}
		s.mu.Unlock()
	}
}

func (s *Scheduler) check(ctx context.Context) {
	for _, workspaceID := range s.workspaceIDs(ctx) {
		s.checkWorkspace(withWorkspaceID(ctx, workspaceID), workspaceID)
	}
}

func (s *Scheduler) checkWorkspace(ctx context.Context, workspaceID string) {
	payload, err := s.store.Load(ctx)
	if err != nil {
		return
	}

	cfg := payload.FeishuBotConfig
	if cfg == nil || !cfg.Enabled {
		return
	}

	now := time.Now()
	today := now.Format("2006-01-02")
	curHour := now.Hour()
	curMinute := now.Minute()
	weekday := int(now.Weekday())
	if weekday == 0 {
		weekday = 7 // Sunday: 0 -> 7
	}

	for _, st := range cfg.SendTimes {
		if curHour*60+curMinute < st.Hour*60+st.Minute {
			continue
		}
		if len(st.Weekdays) > 0 {
			allowed := false
			for _, wd := range st.Weekdays {
				if wd == weekday {
					allowed = true
					break
				}
			}
			if !allowed {
				continue
			}
		}
		key := fmt.Sprintf("%02d:%02d", st.Hour, st.Minute)
		runKey := s.schedulerKey(workspaceID, key)
		if recorder, ok := s.store.(interface {
			HasSuccessfulFeishuRun(context.Context, string, string, string) (bool, error)
		}); ok {
			sent, err := recorder.HasSuccessfulFeishuRun(ctx, workspaceID, key, today)
			if err == nil && sent {
				s.mu.Lock()
				s.lastSent[runKey] = today
				s.mu.Unlock()
				continue
			}
		}
		s.mu.Lock()
		if s.lastSent[runKey] == today {
			s.mu.Unlock()
			continue
		}
		if failedAt, ok := s.lastFailed[runKey]; ok && now.Sub(failedAt) < schedulerFailureCooldown {
			s.mu.Unlock()
			continue
		}
		s.mu.Unlock()

		slog.Info("scheduler sending feishu report", "workspace", workspaceID, "slot", key)
		if err := sendFeishuReport(ctx, *payload); err != nil {
			slog.Warn("scheduler send failed", "workspace", workspaceID, "slot", key, "err", err)
			s.mu.Lock()
			s.lastFailed[runKey] = now
			s.mu.Unlock()
			if recorder, ok := s.store.(interface {
				SaveFeishuRun(context.Context, string, string, string, string, bool, string) error
			}); ok {
				_ = recorder.SaveFeishuRun(ctx, workspaceID, key, today, now.Format("2006-01-02 15:04:05"), false, err.Error())
			}
			return
		}

		s.mu.Lock()
		s.lastSent[runKey] = today
		delete(s.lastFailed, runKey)
		s.mu.Unlock()

		slog.Info("scheduler sent successfully", "workspace", workspaceID, "slot", key)

		sentTime := now.Format("2006-01-02 15:04:05")
		if err := s.store.Update(ctx, func(p *SyncPayload) error {
			if p.FeishuBotConfig == nil {
				return nil
			}
			if p.FeishuBotConfig.LastSentTimes == nil {
				p.FeishuBotConfig.LastSentTimes = make(map[string]string)
			}
			p.FeishuBotConfig.LastSentTimes[key] = today
			p.FeishuBotConfig.LastSentDateTime = sentTime
			return nil
		}); err != nil {
			slog.Warn("scheduler update sync.json failed", "err", err)
		}
		if recorder, ok := s.store.(interface {
			SaveFeishuRun(context.Context, string, string, string, string, bool, string) error
		}); ok {
			_ = recorder.SaveFeishuRun(ctx, workspaceID, key, today, sentTime, true, "")
		}
		return
	}
}

func (s *Scheduler) workspaceIDs(ctx context.Context) []string {
	if lister, ok := s.store.(interface {
		WorkspaceIDs(context.Context) ([]string, error)
	}); ok {
		ids, err := lister.WorkspaceIDs(ctx)
		if err == nil && len(ids) > 0 {
			return ids
		}
	}
	return []string{defaultWorkspaceID}
}

func (s *Scheduler) schedulerKey(workspaceID, slotKey string) string {
	if workspaceID == "" {
		workspaceID = defaultWorkspaceID
	}
	return workspaceID + ":" + slotKey
}
