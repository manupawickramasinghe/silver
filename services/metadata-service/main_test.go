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
			name:     "no newlines",
			input:    "hello world",
			expected: "hello world",
		},
		{
			name:     "newline",
			input:    "hello\nworld",
			expected: "hello world",
		},
		{
			name:     "carriage return",
			input:    "hello\rworld",
			expected: "hello world",
		},
		{
			name:     "both newline and carriage return",
			input:    "hello\r\nworld",
			expected: "hello  world",
		},
		{
			name:     "multiple newlines",
			input:    "hello\n\nworld",
			expected: "hello  world",
		},
		{
			name:     "newline at start",
			input:    "\nhello",
			expected: " hello",
		},
		{
			name:     "newline at end",
			input:    "hello\n",
			expected: "hello ",
		},
		{
			name:     "only newlines and carriage returns",
			input:    "\n\r\n",
			expected: "   ",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			result := sanitizeForLog(tc.input)
			if result != tc.expected {
				t.Errorf("sanitizeForLog(%q) = %q; want %q", tc.input, result, tc.expected)
			}
		})
	}
}
