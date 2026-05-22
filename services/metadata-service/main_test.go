package main

import (
	"os"
	"testing"
)

func TestGetEnvAsInt(t *testing.T) {
	tests := []struct {
		name         string
		envKey       string
		envValue     string
		setEnv       bool
		defaultValue int
		expected     int
	}{
		{
			name:         "valid integer",
			envKey:       "TEST_VALID_INT",
			envValue:     "42",
			setEnv:       true,
			defaultValue: 10,
			expected:     42,
		},
		{
			name:         "invalid integer fallback to default",
			envKey:       "TEST_INVALID_INT",
			envValue:     "not_an_int",
			setEnv:       true,
			defaultValue: 10,
			expected:     10,
		},
		{
			name:         "unset variable fallback to default",
			envKey:       "TEST_UNSET_INT",
			envValue:     "",
			setEnv:       false,
			defaultValue: 10,
			expected:     10,
		},
		{
			name:         "empty string fallback to default",
			envKey:       "TEST_EMPTY_STRING",
			envValue:     "",
			setEnv:       true,
			defaultValue: 10,
			expected:     10,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.setEnv {
				os.Setenv(tt.envKey, tt.envValue)
				defer os.Unsetenv(tt.envKey)
			} else {
				os.Unsetenv(tt.envKey)
			}

			result := getEnvAsInt(tt.envKey, tt.defaultValue)
			if result != tt.expected {
				t.Errorf("getEnvAsInt() = %v, want %v", result, tt.expected)
			}
		})
	}
}
