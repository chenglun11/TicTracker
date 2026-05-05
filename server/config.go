package main

import (
	"log/slog"
	"os"
	"strconv"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Port                    string `yaml:"port"`
	Bind                    string `yaml:"bind"` // 默认 127.0.0.1，仅本机访问
	Token                   string `yaml:"token"`
	SyncToken               string `yaml:"sync_token"`
	WebToken                string `yaml:"web_token"`
	DataDir                 string `yaml:"data_dir"`
	MaxBodyBytes            int64  `yaml:"max_body_bytes"`
	FeishuSecret            string `yaml:"feishu_secret"`
	FeishuAppID             string `yaml:"feishu_app_id"`
	FeishuAppSecret         string `yaml:"feishu_app_secret"`
	FeishuVerificationToken string `yaml:"feishu_verification_token"`
	FeishuEncryptKey        string `yaml:"feishu_encrypt_key"`
}

func (c *Config) SyncAccessToken() string {
	if c.SyncToken != "" {
		return c.SyncToken
	}
	return c.Token
}

func (c *Config) WebAccessToken() string {
	if c.WebToken != "" {
		return c.WebToken
	}
	return c.Token
}

func LoadConfig(path string) (*Config, error) {
	cfg := &Config{
		Port:         "9999",
		Bind:         "127.0.0.1",
		DataDir:      "./data",
		MaxBodyBytes: 10 << 20, // 10MB
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			applyEnvOverrides(cfg)
			return cfg, nil
		}
		return nil, err
	}

	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, err
	}

	// 检查 config 文件权限：包含密钥应为 0600
	if info, err := os.Stat(path); err == nil {
		if info.Mode().Perm()&0o077 != 0 {
			slog.Warn("config file permissions too open, recommend chmod 600",
				"path", path, "perm", info.Mode().Perm())
		}
	}

	applyEnvOverrides(cfg)
	return cfg, nil
}

func applyEnvOverrides(cfg *Config) {
	if v := os.Getenv("PORT"); v != "" {
		cfg.Port = v
	}
	if v := os.Getenv("BIND"); v != "" {
		cfg.Bind = v
	}
	if v := os.Getenv("AUTH_TOKEN"); v != "" {
		cfg.Token = v
	}
	if v := os.Getenv("SYNC_AUTH_TOKEN"); v != "" {
		cfg.SyncToken = v
	}
	if v := os.Getenv("WEB_AUTH_TOKEN"); v != "" {
		cfg.WebToken = v
	}
	if v := os.Getenv("DATA_DIR"); v != "" {
		cfg.DataDir = v
	}
	if v := os.Getenv("MAX_BODY_BYTES"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			cfg.MaxBodyBytes = n
		}
	}
	if v := os.Getenv("FEISHU_SECRET"); v != "" {
		cfg.FeishuSecret = v
	}
	if v := os.Getenv("FEISHU_APP_ID"); v != "" {
		cfg.FeishuAppID = v
	}
	if v := os.Getenv("FEISHU_APP_SECRET"); v != "" {
		cfg.FeishuAppSecret = v
	}
	if v := os.Getenv("FEISHU_VERIFICATION_TOKEN"); v != "" {
		cfg.FeishuVerificationToken = v
	}
	if v := os.Getenv("FEISHU_ENCRYPT_KEY"); v != "" {
		cfg.FeishuEncryptKey = v
	}
}
