package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAPIKeyAuthMiddleware(t *testing.T) {
	// Dummy handler to check if it gets called
	called := false
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	})

	middleware := apiKeyAuthMiddleware(nextHandler)

	tests := []struct {
		name           string
		configKey      string
		headerKey      string
		expectCalled   bool
		expectedStatus int
		expectedError  string
	}{
		{
			name:           "Empty API Key in config skips auth",
			configKey:      "",
			headerKey:      "", // doesn't matter
			expectCalled:   true,
			expectedStatus: http.StatusOK,
			expectedError:  "",
		},
		{
			name:           "Missing API Key header",
			configKey:      "secret-key",
			headerKey:      "",
			expectCalled:   false,
			expectedStatus: http.StatusUnauthorized,
			expectedError:  "Missing API key",
		},
		{
			name:           "Invalid API Key header",
			configKey:      "secret-key",
			headerKey:      "wrong-key",
			expectCalled:   false,
			expectedStatus: http.StatusUnauthorized,
			expectedError:  "Invalid API key",
		},
		{
			name:           "Valid API Key header",
			configKey:      "secret-key",
			headerKey:      "secret-key",
			expectCalled:   true,
			expectedStatus: http.StatusOK,
			expectedError:  "",
		},
	}

	// Backup original config and restore after test
	originalConfig := config
	defer func() { config = originalConfig }()

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Reset state
			called = false
			config.APIKey = tt.configKey

			req := httptest.NewRequest("GET", "/protected", nil)
			if tt.headerKey != "" {
				req.Header.Set("X-API-Key", tt.headerKey)
			}
			w := httptest.NewRecorder()

			middleware.ServeHTTP(w, req)

			if called != tt.expectCalled {
				t.Errorf("Expected next handler to be called: %v, got: %v", tt.expectCalled, called)
			}

			if w.Code != tt.expectedStatus {
				t.Errorf("Expected status %d, got %d", tt.expectedStatus, w.Code)
			}

			if tt.expectedError != "" {
				var response map[string]string
				if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
					t.Fatalf("Failed to decode response body: %v", err)
				}
				if response["error"] != tt.expectedError {
					t.Errorf("Expected error %q, got %q", tt.expectedError, response["error"])
				}
			}
		})
	}
}
