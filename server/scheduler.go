package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"
)

type Scheduler struct {
	cfg      *Config
	dataDir  string
	lastSent map[string]string // "HH:MM" -> "YYYY-MM-DD"
}

func NewScheduler(cfg *Config, dataDir string) *Scheduler {
	return &Scheduler{
		cfg:      cfg,
		dataDir:  dataDir,
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
	path := filepath.Join(s.dataDir, "sync.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}

	var payload SyncPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		log.Printf("[scheduler] failed to parse sync.json: %v", err)
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

	for _, st := range cfg.SendTimes {
		if st.Hour != curHour || st.Minute != curMinute {
			continue
		}
		key := fmt.Sprintf("%02d:%02d", st.Hour, st.Minute)
		if s.lastSent[key] == today {
			continue
		}

		log.Printf("[scheduler] sending feishu report for %s", key)
		if err := sendFeishuReport(payload, s.cfg.FeishuSecret); err != nil {
			log.Printf("[scheduler] send failed: %v", err)
			continue
		}

		s.lastSent[key] = today
		log.Printf("[scheduler] sent successfully for %s", key)

		// 更新 sync.json 中的 lastSentTimes 和 lastSentDateTime
		if cfg.LastSentTimes == nil {
			cfg.LastSentTimes = make(map[string]string)
		}
		cfg.LastSentTimes[key] = today
		cfg.LastSentDateTime = now.Format("2006-01-02 15:04:05")
		payload.FeishuBotConfig = cfg

		updated, err := json.MarshalIndent(payload, "", "  ")
		if err != nil {
			log.Printf("[scheduler] failed to marshal updated payload: %v", err)
			continue
		}

		tmpPath := path + ".tmp"
		if err := os.WriteFile(tmpPath, updated, 0644); err != nil {
			log.Printf("[scheduler] failed to write tmp file: %v", err)
			continue
		}
		if err := os.Rename(tmpPath, path); err != nil {
			log.Printf("[scheduler] failed to rename tmp file: %v", err)
			os.Remove(tmpPath)
		}
	}
}
