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
		isSet        bool
		defaultValue string
		expected     string
	}{
		{
			name:         "Variable is set",
			key:          "TEST_ENV_VAR",
			envValue:     "hello",
			isSet:        true,
			defaultValue: "default",
			expected:     "hello",
		},
		{
			name:         "Variable is not set",
			key:          "TEST_ENV_VAR",
			envValue:     "",
			isSet:        false,
			defaultValue: "default",
			expected:     "default",
		},
		{
			name:         "Variable is empty string",
			key:          "TEST_ENV_VAR",
			envValue:     "",
			isSet:        true,
			defaultValue: "default",
			expected:     "default",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if tc.isSet {
				os.Setenv(tc.key, tc.envValue)
				defer os.Unsetenv(tc.key)
			} else {
				os.Unsetenv(tc.key)
			}

			result := getEnv(tc.key, tc.defaultValue)
			if result != tc.expected {
				t.Errorf("getEnv(%q, %q) = %q; want %q", tc.key, tc.defaultValue, result, tc.expected)
			}
		})
	}
}

func TestGetEnvAsInt(t *testing.T) {
	tests := []struct {
		name         string
		key          string
		envValue     string
		isSet        bool
		defaultValue int
		expected     int
	}{
		{
			name:         "Variable is set to valid int",
			key:          "TEST_ENV_INT",
			envValue:     "42",
			isSet:        true,
			defaultValue: 10,
			expected:     42,
		},
		{
			name:         "Variable is not set",
			key:          "TEST_ENV_INT",
			envValue:     "",
			isSet:        false,
			defaultValue: 10,
			expected:     10,
		},
		{
			name:         "Variable is set to empty string",
			key:          "TEST_ENV_INT",
			envValue:     "",
			isSet:        true,
			defaultValue: 10,
			expected:     10,
		},
		{
			name:         "Variable is set to invalid string",
			key:          "TEST_ENV_INT",
			envValue:     "not_an_int",
			isSet:        true,
			defaultValue: 10,
			expected:     10,
		},
		{
			name:         "Variable is set to negative int",
			key:          "TEST_ENV_INT",
			envValue:     "-5",
			isSet:        true,
			defaultValue: 10,
			expected:     -5,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if tc.isSet {
				os.Setenv(tc.key, tc.envValue)
				defer os.Unsetenv(tc.key)
			} else {
				os.Unsetenv(tc.key)
			}

			result := getEnvAsInt(tc.key, tc.defaultValue)
			if result != tc.expected {
				t.Errorf("getEnvAsInt(%q, %d) = %d; want %d", tc.key, tc.defaultValue, result, tc.expected)
			}
		})
	}
}
