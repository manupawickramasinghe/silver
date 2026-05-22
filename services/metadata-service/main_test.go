package main

import (
	"os"
	"testing"
)

func TestGetEnvAsInt(t *testing.T) {
	// Setup test cases
	tests := []struct {
		name         string
		envKey       string
		envValue     string
		setEnv       bool
		defaultValue int
		expected     int
	}{
		{
			name:         "Valid integer value",
			envKey:       "TEST_INT_VALID",
			envValue:     "42",
			setEnv:       true,
			defaultValue: 10,
			expected:     42,
		},
		{
			name:         "Invalid string value (not an int)",
			envKey:       "TEST_INT_INVALID",
			envValue:     "not_an_int",
			setEnv:       true,
			defaultValue: 10,
			expected:     10,
		},
		{
			name:         "Empty string value",
			envKey:       "TEST_INT_EMPTY",
			envValue:     "",
			setEnv:       true,
			defaultValue: 10,
			expected:     10,
		},
		{
			name:         "Unset variable",
			envKey:       "TEST_INT_UNSET",
			envValue:     "",
			setEnv:       false,
			defaultValue: 10,
			expected:     10,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Manage environment variables for isolation
			if tt.setEnv {
				os.Setenv(tt.envKey, tt.envValue)
				defer os.Unsetenv(tt.envKey)
			} else {
				// Ensure it's unset in case it exists in the outer environment
				os.Unsetenv(tt.envKey)
			}

			// Call the function
			result := getEnvAsInt(tt.envKey, tt.defaultValue)

			// Assert the result
			if result != tt.expected {
				t.Errorf("getEnvAsInt(%q, %d) = %d; want %d", tt.envKey, tt.defaultValue, result, tt.expected)
			}
		})
	}
}
