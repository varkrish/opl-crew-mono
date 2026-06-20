package config

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type EnvironmentConfig struct {
	URL      string `json:"url"`
	Insecure bool   `json:"insecure"`
	Token    string `json:"token,omitempty"`
}

type CLIConfig struct {
	CurrentEnv   string                       `json:"current_env"`
	Environments map[string]EnvironmentConfig `json:"environments"`
}

func GetConfigPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".opl-cli", "config.json")
}

func LoadConfig() *CLIConfig {
	path := GetConfigPath()
	data, err := os.ReadFile(path)
	if err != nil {
		// Return default
		return &CLIConfig{
			CurrentEnv: "default",
			Environments: map[string]EnvironmentConfig{
				"default": {URL: "http://localhost:8081", Insecure: true},
			},
		}
	}

	var cfg CLIConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return &CLIConfig{
			CurrentEnv: "default",
			Environments: map[string]EnvironmentConfig{
				"default": {URL: "http://localhost:8081", Insecure: true},
			},
		}
	}
	return &cfg
}

func SaveConfig(cfg *CLIConfig) error {
	path := GetConfigPath()
	os.MkdirAll(filepath.Dir(path), 0755)

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func GetActiveEnv() EnvironmentConfig {
	cfg := LoadConfig()
	if env, ok := cfg.Environments[cfg.CurrentEnv]; ok {
		return env
	}
	return EnvironmentConfig{URL: "http://localhost:8081", Insecure: true}
}
