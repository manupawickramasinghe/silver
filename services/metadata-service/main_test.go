package main

import (
	"os"
	"testing"
)

func TestGetEnv(t *testing.T) {
	tests := []struct {
		name         string
		key          string
		envValue     string
		setEnv       bool
		defaultValue string
		expected     string
	}{
		{
			name:         "returns env value when set",
			key:          "TEST_KEY_1",
			envValue:     "test_value",
			setEnv:       true,
			defaultValue: "default",
			expected:     "test_value",
		},
		{
			name:         "returns default when env not set",
			key:          "TEST_KEY_2",
			envValue:     "",
			setEnv:       false,
			defaultValue: "default",
			expected:     "default",
		},
		{
			name:         "returns default when env is empty string",
			key:          "TEST_KEY_3",
			envValue:     "",
			setEnv:       true,
			defaultValue: "default",
			expected:     "default",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.setEnv {
				os.Setenv(tt.key, tt.envValue)
				defer os.Unsetenv(tt.key)
			}

			result := getEnv(tt.key, tt.defaultValue)
			if result != tt.expected {
				t.Errorf("getEnv() = %v, want %v", result, tt.expected)
			}
		})
	}
}
