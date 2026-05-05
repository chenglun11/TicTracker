package main

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

type Scheduler struct {
	cfg      *Config
	store    *Store
	mu       sync.Mutex
	lastSent map[string]string // "HH:MM" -> "YYYY-MM-DD"
}

func NewScheduler(cfg *Config, store *Store) *Scheduler {
	return &Scheduler{
		cfg:      cfg,
		store:    store,
		lastSent: make(map[string]string),
	}
}

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
	payload, err := s.store.Load(ctx)
	if err != nil || payload.FeishuBotConfig == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for key, date := range payload.FeishuBotConfig.LastSentTimes {
		s.lastSent[key] = date
	}
}

func (s *Scheduler) check(ctx context.Context) {
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
		if st.Hour != curHour || st.Minute != curMinute {
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
		s.mu.Lock()
		if s.lastSent[key] == today {
			s.mu.Unlock()
			continue
		}
		s.mu.Unlock()

		slog.Info("scheduler sending feishu report", "slot", key)
		if err := sendFeishuReport(ctx, *payload); err != nil {
			slog.Warn("scheduler send failed", "slot", key, "err", err)
			continue
		}

		s.mu.Lock()
		s.lastSent[key] = today
		s.mu.Unlock()

		slog.Info("scheduler sent successfully", "slot", key)

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
	}
}
