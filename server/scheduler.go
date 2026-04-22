package main

import (
	"fmt"
	"log"
	"time"
)

type Scheduler struct {
	cfg      *Config
	store    *Store
	lastSent map[string]string // "HH:MM" -> "YYYY-MM-DD"
}

func NewScheduler(cfg *Config, store *Store) *Scheduler {
	return &Scheduler{
		cfg:      cfg,
		store:    store,
		lastSent: make(map[string]string),
	}
}

func (s *Scheduler) Start() {
	log.Println("[scheduler] started, checking every 30s")
	for {
		s.check()
		time.Sleep(30 * time.Second)
	}
}

func (s *Scheduler) check() {
	payload, err := s.store.Load()
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
		// 检查星期限制
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
		if s.lastSent[key] == today {
			continue
		}

		log.Printf("[scheduler] sending feishu report for %s", key)
		if err := sendFeishuReport(*payload); err != nil {
			log.Printf("[scheduler] send failed: %v", err)
			continue
		}

		s.lastSent[key] = today
		log.Printf("[scheduler] sent successfully for %s", key)

		// 原子更新 lastSentTimes 和 lastSentDateTime
		sentTime := now.Format("2006-01-02 15:04:05")
		if err := s.store.Update(func(p *SyncPayload) error {
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
			log.Printf("[scheduler] failed to update sync.json: %v", err)
		}
	}
}
