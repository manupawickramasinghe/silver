package main

import (
	"os"
	"testing"
)

func TestGetEnv(t *testing.T) {
	// Setup
	os.Setenv("TEST_KEY_EXISTS", "test_value")
	os.Setenv("TEST_KEY_EMPTY", "")
	defer os.Unsetenv("TEST_KEY_EXISTS")
	defer os.Unsetenv("TEST_KEY_EMPTY")

	tests := []struct {
		name         string
		key          string
		defaultValue string
		want         string
	}{
		{
			name:         "key exists with value",
			key:          "TEST_KEY_EXISTS",
			defaultValue: "default_value",
			want:         "test_value",
		},
		{
			name:         "key exists but empty string",
			key:          "TEST_KEY_EMPTY",
			defaultValue: "default_value",
			want:         "default_value",
		},
		{
			name:         "key does not exist",
			key:          "TEST_KEY_NOT_EXISTS",
			defaultValue: "default_value",
			want:         "default_value",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := getEnv(tt.key, tt.defaultValue); got != tt.want {
				t.Errorf("getEnv() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGetEnvAsInt(t *testing.T) {
	// Setup
	os.Setenv("TEST_INT_EXISTS", "42")
	os.Setenv("TEST_INT_INVALID", "invalid")
	os.Setenv("TEST_INT_EMPTY", "")
	defer os.Unsetenv("TEST_INT_EXISTS")
	defer os.Unsetenv("TEST_INT_INVALID")
	defer os.Unsetenv("TEST_INT_EMPTY")

	tests := []struct {
		name         string
		key          string
		defaultValue int
		want         int
	}{
		{
			name:         "key exists with valid int",
			key:          "TEST_INT_EXISTS",
			defaultValue: 10,
			want:         42,
		},
		{
			name:         "key exists with invalid int",
			key:          "TEST_INT_INVALID",
			defaultValue: 10,
			want:         10,
		},
		{
			name:         "key exists but empty string",
			key:          "TEST_INT_EMPTY",
			defaultValue: 10,
			want:         10,
		},
		{
			name:         "key does not exist",
			key:          "TEST_INT_NOT_EXISTS",
			defaultValue: 10,
			want:         10,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := getEnvAsInt(tt.key, tt.defaultValue); got != tt.want {
				t.Errorf("getEnvAsInt() = %v, want %v", got, tt.want)
			}
		})
	}
}
