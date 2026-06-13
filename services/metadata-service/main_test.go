package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAPIKeyAuthMiddleware(t *testing.T) {
	// Save the original config to restore later
	originalConfig := config
	defer func() { config = originalConfig }()

	// Dummy handler to serve as the "next" handler
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	tests := []struct {
		name           string
		configuredKey  string
		headerKey      string
		expectedStatus int
		expectedBody   string // optional substring match
	}{
		{
			name:           "API_KEY not configured, skips authentication",
			configuredKey:  "",
			headerKey:      "any-key",
			expectedStatus: http.StatusOK,
			expectedBody:   "OK",
		},
		{
			name:           "API_KEY configured, but missing from request",
			configuredKey:  "secret-key",
			headerKey:      "",
			expectedStatus: http.StatusUnauthorized,
			expectedBody:   "Missing API key",
		},
		{
			name:           "API_KEY configured, but invalid in request",
			configuredKey:  "secret-key",
			headerKey:      "wrong-key",
			expectedStatus: http.StatusUnauthorized,
			expectedBody:   "Invalid API key",
		},
		{
			name:           "API_KEY configured and valid in request",
			configuredKey:  "secret-key",
			headerKey:      "secret-key",
			expectedStatus: http.StatusOK,
			expectedBody:   "OK",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set the global config for this test case
			config.APIKey = tt.configuredKey

			// Create a new HTTP request
			req := httptest.NewRequest("GET", "/protected", nil)
			if tt.headerKey != "" {
				req.Header.Set("X-API-Key", tt.headerKey)
			}

			// Create a ResponseRecorder to record the response
			rr := httptest.NewRecorder()

			// Call the middleware with our dummy next handler
			handler := apiKeyAuthMiddleware(nextHandler)
			handler.ServeHTTP(rr, req)

			// Check the status code
			if status := rr.Code; status != tt.expectedStatus {
				t.Errorf("handler returned wrong status code: got %v want %v",
					status, tt.expectedStatus)
			}

			// Check the response body for the expected substring
			if tt.expectedBody != "" {
				body := rr.Body.String()
				if !strings.Contains(body, tt.expectedBody) {
					t.Errorf("handler returned unexpected body: got %v want to contain %v",
						body, tt.expectedBody)
				}
			}
		})
	}
}
