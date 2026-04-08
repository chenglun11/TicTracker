package main

import (
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Port         string `yaml:"port"`
	Token        string `yaml:"token"`
	DataDir      string `yaml:"data_dir"`
	FeishuSecret string `yaml:"feishu_secret"`
}

func LoadConfig(path string) (*Config, error) {
	cfg := &Config{
		Port:    "8080",
		DataDir: "./data",
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

	applyEnvOverrides(cfg)
	return cfg, nil
}

func applyEnvOverrides(cfg *Config) {
	if v := os.Getenv("PORT"); v != "" {
		cfg.Port = v
	}
	if v := os.Getenv("AUTH_TOKEN"); v != "" {
		cfg.Token = v
	}
	if v := os.Getenv("DATA_DIR"); v != "" {
		cfg.DataDir = v
	}
	if v := os.Getenv("FEISHU_SECRET"); v != "" {
		cfg.FeishuSecret = v
	}
}
