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
			name:     "single newline",
			input:    "hello\nworld",
			expected: "hello world",
		},
		{
			name:     "single carriage return",
			input:    "hello\rworld",
			expected: "hello world",
		},
		{
			name:     "crlf",
			input:    "hello\r\nworld",
			expected: "hello  world",
		},
		{
			name:     "multiple newlines",
			input:    "hello\n\nworld",
			expected: "hello  world",
		},
		{
			name:     "newlines at start and end",
			input:    "\nhello world\n",
			expected: " hello world ",
		},
		{
			name:     "mixed newlines and carriage returns",
			input:    "a\rb\nc\r\nd",
			expected: "a b c  d",
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
