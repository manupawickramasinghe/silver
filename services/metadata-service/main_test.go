package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCorsMiddleware(t *testing.T) {
	// Dummy handler to wrap
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	tests := []struct {
		name           string
		allowedOrigins []string
		reqOrigin      string
		reqMethod      string
		expectedOrigin string
		expectedVary   string
		expectedStatus int
	}{
		{
			name:           "Wildcard allowed",
			allowedOrigins: []string{"*"},
			reqOrigin:      "http://example.com",
			reqMethod:      "GET",
			expectedOrigin: "*",
			expectedVary:   "Origin",
			expectedStatus: http.StatusOK,
		},
		{
			name:           "Specific origin allowed",
			allowedOrigins: []string{"http://example.com", "https://app.example.com"},
			reqOrigin:      "https://app.example.com",
			reqMethod:      "GET",
			expectedOrigin: "https://app.example.com",
			expectedVary:   "Origin",
			expectedStatus: http.StatusOK,
		},
		{
			name:           "Origin not allowed",
			allowedOrigins: []string{"http://example.com"},
			reqOrigin:      "http://evil.com",
			reqMethod:      "GET",
			expectedOrigin: "",
			expectedVary:   "",
			expectedStatus: http.StatusOK,
		},
		{
			name:           "No origin header",
			allowedOrigins: []string{"http://example.com"},
			reqOrigin:      "",
			reqMethod:      "GET",
			expectedOrigin: "",
			expectedVary:   "",
			expectedStatus: http.StatusOK,
		},
		{
			name:           "OPTIONS request allowed",
			allowedOrigins: []string{"http://example.com"},
			reqOrigin:      "http://example.com",
			reqMethod:      "OPTIONS",
			expectedOrigin: "http://example.com",
			expectedVary:   "Origin",
			expectedStatus: http.StatusOK,
		},
		{
			name:           "OPTIONS request not allowed origin",
			allowedOrigins: []string{"http://example.com"},
			reqOrigin:      "http://evil.com",
			reqMethod:      "OPTIONS",
			expectedOrigin: "",
			expectedVary:   "",
			expectedStatus: http.StatusOK,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Save current config to restore later
			originalConfig := config
			defer func() { config = originalConfig }()

			// Setup config
			config.AllowedOrigins = tt.allowedOrigins

			// Create request
			req := httptest.NewRequest(tt.reqMethod, "/health", nil)
			if tt.reqOrigin != "" {
				req.Header.Set("Origin", tt.reqOrigin)
			}

			// Record response
			rr := httptest.NewRecorder()

			// Run middleware
			handler := corsMiddleware(nextHandler)
			handler.ServeHTTP(rr, req)

			// Check response
			if status := rr.Code; status != tt.expectedStatus {
				t.Errorf("handler returned wrong status code: got %v want %v", status, tt.expectedStatus)
			}

			if origin := rr.Header().Get("Access-Control-Allow-Origin"); origin != tt.expectedOrigin {
				t.Errorf("handler returned wrong Access-Control-Allow-Origin header: got %v want %v", origin, tt.expectedOrigin)
			}

			if vary := rr.Header().Get("Vary"); vary != tt.expectedVary {
				t.Errorf("handler returned wrong Vary header: got %v want %v", vary, tt.expectedVary)
			}

			if methods := rr.Header().Get("Access-Control-Allow-Methods"); methods != "GET, POST, OPTIONS" {
				t.Errorf("handler returned wrong Access-Control-Allow-Methods header: got %v want %v", methods, "GET, POST, OPTIONS")
			}

			if headers := rr.Header().Get("Access-Control-Allow-Headers"); headers != "Content-Type, X-API-Key" {
				t.Errorf("handler returned wrong Access-Control-Allow-Headers header: got %v want %v", headers, "Content-Type, X-API-Key")
			}

			// Ensure OPTIONS doesn't pass to next handler
			if tt.reqMethod == "OPTIONS" {
				if rr.Body.String() == "OK" {
					t.Errorf("OPTIONS request passed to next handler")
				}
			} else {
				if rr.Body.String() != "OK" {
					t.Errorf("non-OPTIONS request did not pass to next handler")
				}
			}
		})
	}
}
