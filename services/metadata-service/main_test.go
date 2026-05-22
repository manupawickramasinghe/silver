package main

import (
	"testing"
)

func TestSanitizeForLog(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "empty string",
			input:    "",
			expected: "",
		},
		{
			name:     "no newlines or carriage returns",
			input:    "hello world",
			expected: "hello world",
		},
		{
			name:     "string with newline",
			input:    "hello\nworld",
			expected: "hello world",
		},
		{
			name:     "string with carriage return",
			input:    "hello\rworld",
			expected: "hello world",
		},
		{
			name:     "string with both newline and carriage return",
			input:    "hello\r\nworld",
			expected: "hello  world",
		},
		{
			name:     "string with multiple newlines and carriage returns",
			input:    "multi\nline\rtext\r\nhere",
			expected: "multi line text  here",
		},
		{
			name:     "starts and ends with newline",
			input:    "\nhello\n",
			expected: " hello ",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := sanitizeForLog(tt.input)
			if result != tt.expected {
				t.Errorf("sanitizeForLog(%q) = %q; expected %q", tt.input, result, tt.expected)
			}
		})
	}
}
