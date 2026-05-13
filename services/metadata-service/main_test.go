package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCORSMiddleware(t *testing.T) {
	// A dummy handler that will return 200 OK
	dummyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	tests := []struct {
		name           string
		allowedOrigins string
		requestOrigin  string
		expectedOrigin string
	}{
		{
			name:           "Wildcard AllowedOrigins",
			allowedOrigins: "*",
			requestOrigin:  "https://example.com",
			expectedOrigin: "*",
		},
		{
			name:           "Allowed Origin Matching",
			allowedOrigins: "https://example.com,https://test.com",
			requestOrigin:  "https://example.com",
			expectedOrigin: "https://example.com",
		},
		{
			name:           "Allowed Origin Matching With Spaces",
			allowedOrigins: "https://example.com, https://test.com",
			requestOrigin:  "https://test.com",
			expectedOrigin: "https://test.com",
		},
		{
			name:           "Disallowed Origin",
			allowedOrigins: "https://example.com,https://test.com",
			requestOrigin:  "https://malicious.com",
			expectedOrigin: "", // No Access-Control-Allow-Origin header
		},
		{
			name:           "Empty AllowedOrigins",
			allowedOrigins: "",
			requestOrigin:  "https://example.com",
			expectedOrigin: "",
		},
		{
			name:           "No Request Origin",
			allowedOrigins: "https://example.com",
			requestOrigin:  "",
			expectedOrigin: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Update the global config for this test case
			config = Config{
				AllowedOrigins: tc.allowedOrigins,
			}

			req := httptest.NewRequest("GET", "/", nil)
			if tc.requestOrigin != "" {
				req.Header.Set("Origin", tc.requestOrigin)
			}

			rr := httptest.NewRecorder()

			// Create middleware handler
			handler := corsMiddleware(dummyHandler)

			// Serve HTTP
			handler.ServeHTTP(rr, req)

			// Check response headers
			actualOrigin := rr.Header().Get("Access-Control-Allow-Origin")
			if actualOrigin != tc.expectedOrigin {
				t.Errorf("Expected Access-Control-Allow-Origin to be %q, got %q", tc.expectedOrigin, actualOrigin)
			}

			// Check Vary header if origin was allowed
			if tc.expectedOrigin != "" {
				varyHeader := rr.Header().Get("Vary")
				if varyHeader != "Origin" {
					t.Errorf("Expected Vary header to be 'Origin', got %q", varyHeader)
				}
			}
		})
	}
}
