package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func TestSanitizeForLog(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{"no newlines", "hello world", "hello world"},
		{"with newline", "hello\nworld", "hello world"},
		{"with carriage return", "hello\rworld", "hello world"},
		{"with both", "hello\r\nworld", "hello  world"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := sanitizeForLog(tt.input)
			if result != tt.expected {
				t.Errorf("sanitizeForLog(%q) = %q; want %q", tt.input, result, tt.expected)
			}
		})
	}
}

func TestGetEnv(t *testing.T) {
	t.Run("EnvVarExists", func(t *testing.T) {
		key := "TEST_ENV_VAR"
		expected := "test_value"
		os.Setenv(key, expected)
		defer os.Unsetenv(key)

		result := getEnv(key, "default")
		if result != expected {
			t.Errorf("getEnv() = %q; want %q", result, expected)
		}
	})

	t.Run("EnvVarDoesNotExist", func(t *testing.T) {
		result := getEnv("NON_EXISTENT_VAR", "default_value")
		if result != "default_value" {
			t.Errorf("getEnv() = %q; want %q", result, "default_value")
		}
	})
}

func TestGetEnvAsInt(t *testing.T) {
	t.Run("ValidInt", func(t *testing.T) {
		key := "TEST_INT_VAR"
		os.Setenv(key, "42")
		defer os.Unsetenv(key)

		result := getEnvAsInt(key, 10)
		if result != 42 {
			t.Errorf("getEnvAsInt() = %d; want 42", result)
		}
	})

	t.Run("InvalidInt", func(t *testing.T) {
		key := "TEST_INVALID_INT"
		os.Setenv(key, "not_a_number")
		defer os.Unsetenv(key)

		result := getEnvAsInt(key, 10)
		if result != 10 {
			t.Errorf("getEnvAsInt() = %d; want 10", result)
		}
	})

	t.Run("MissingVar", func(t *testing.T) {
		result := getEnvAsInt("NON_EXISTENT_INT", 10)
		if result != 10 {
			t.Errorf("getEnvAsInt() = %d; want 10", result)
		}
	})
}

func TestHealthHandler(t *testing.T) {
	req := httptest.NewRequest("GET", "/health", nil)
	rr := httptest.NewRecorder()

	healthHandler(rr, req)

	if status := rr.Code; status != http.StatusOK {
		t.Errorf("handler returned wrong status code: got %v want %v", status, http.StatusOK)
	}

	var response map[string]string
	if err := json.NewDecoder(rr.Body).Decode(&response); err != nil {
		t.Fatalf("could not decode response: %v", err)
	}

	if response["status"] != "healthy" {
		t.Errorf("expected status 'healthy', got %v", response["status"])
	}
}

func TestAPIKeyAuthMiddleware(t *testing.T) {
	// Backup original config
	originalAPIKey := config.APIKey
	defer func() { config.APIKey = originalAPIKey }()

	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	middleware := apiKeyAuthMiddleware(nextHandler)

	t.Run("NoAPIKeyConfigured", func(t *testing.T) {
		config.APIKey = ""
		req := httptest.NewRequest("GET", "/", nil)
		rr := httptest.NewRecorder()

		middleware.ServeHTTP(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("expected OK, got %v", rr.Code)
		}
	})

	t.Run("MissingAPIKeyHeader", func(t *testing.T) {
		config.APIKey = "secret-key"
		req := httptest.NewRequest("GET", "/", nil)
		rr := httptest.NewRecorder()

		middleware.ServeHTTP(rr, req)

		if rr.Code != http.StatusUnauthorized {
			t.Errorf("expected Unauthorized, got %v", rr.Code)
		}
	})

	t.Run("InvalidAPIKey", func(t *testing.T) {
		config.APIKey = "secret-key"
		req := httptest.NewRequest("GET", "/", nil)
		req.Header.Set("X-API-Key", "wrong-key")
		rr := httptest.NewRecorder()

		middleware.ServeHTTP(rr, req)

		if rr.Code != http.StatusUnauthorized {
			t.Errorf("expected Unauthorized, got %v", rr.Code)
		}
	})

	t.Run("ValidAPIKey", func(t *testing.T) {
		config.APIKey = "secret-key"
		req := httptest.NewRequest("GET", "/", nil)
		req.Header.Set("X-API-Key", "secret-key")
		rr := httptest.NewRecorder()

		middleware.ServeHTTP(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("expected OK, got %v", rr.Code)
		}
	})
}

func TestReceiveSuperPlatformResultHandler(t *testing.T) {
	t.Run("ValidPayload", func(t *testing.T) {
		payload := `{"status": "success", "data": {"key": "value"}, "timestamp": "2023-01-01T00:00:00Z"}`
		req := httptest.NewRequest("POST", "/api/results", bytes.NewBufferString(payload))
		rr := httptest.NewRecorder()

		receiveSuperPlatformResultHandler(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("expected OK, got %v", rr.Code)
		}

		var response map[string]interface{}
		if err := json.NewDecoder(rr.Body).Decode(&response); err != nil {
			t.Fatalf("could not decode response: %v", err)
		}

		if success, ok := response["success"].(bool); !ok || !success {
			t.Errorf("expected success=true, got %v", response["success"])
		}
	})

	t.Run("InvalidPayload", func(t *testing.T) {
		payload := `{"status": "success", invalid json}`
		req := httptest.NewRequest("POST", "/api/results", bytes.NewBufferString(payload))
		rr := httptest.NewRecorder()

		receiveSuperPlatformResultHandler(rr, req)

		if rr.Code != http.StatusBadRequest {
			t.Errorf("expected Bad Request, got %v", rr.Code)
		}
	})
}
