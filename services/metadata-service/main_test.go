package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestValidateConfig(t *testing.T) {
	tests := []struct {
		name    string
		config  Config
		wantErr bool
	}{
		{
			name:    "api key set",
			config:  Config{APIKey: "secret"},
			wantErr: false,
		},
		{
			name:    "api key missing",
			config:  Config{},
			wantErr: true,
		},
		{
			name:    "api key missing but unauthenticated access allowed",
			config:  Config{AllowUnauthenticated: true},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateConfig(tt.config)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateConfig() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestAPIKeyAuthMiddleware(t *testing.T) {
	tests := []struct {
		name         string
		config       Config
		header       string
		sendHeader   bool
		wantStatus   int
		wantNextCall bool
	}{
		{
			name:         "valid key is accepted",
			config:       Config{APIKey: "secret"},
			header:       "secret",
			sendHeader:   true,
			wantStatus:   http.StatusOK,
			wantNextCall: true,
		},
		{
			name:         "wrong key is rejected",
			config:       Config{APIKey: "secret"},
			header:       "wrong",
			sendHeader:   true,
			wantStatus:   http.StatusUnauthorized,
			wantNextCall: false,
		},
		{
			name:         "key of a different length is rejected",
			config:       Config{APIKey: "secret"},
			header:       "secret-but-longer",
			sendHeader:   true,
			wantStatus:   http.StatusUnauthorized,
			wantNextCall: false,
		},
		{
			name:         "missing header is rejected",
			config:       Config{APIKey: "secret"},
			sendHeader:   false,
			wantStatus:   http.StatusUnauthorized,
			wantNextCall: false,
		},
		{
			name:         "empty header is rejected",
			config:       Config{APIKey: "secret"},
			header:       "",
			sendHeader:   true,
			wantStatus:   http.StatusUnauthorized,
			wantNextCall: false,
		},
		{
			name:         "unauthenticated access allowed on purpose",
			config:       Config{AllowUnauthenticated: true},
			sendHeader:   false,
			wantStatus:   http.StatusOK,
			wantNextCall: true,
		},
	}

	original := config
	t.Cleanup(func() { config = original })

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config = tt.config

			called := false
			handler := apiKeyAuthMiddleware(func(w http.ResponseWriter, r *http.Request) {
				called = true
				w.WriteHeader(http.StatusOK)
			})

			req := httptest.NewRequest(http.MethodPost, "/api/results", nil)
			if tt.sendHeader {
				req.Header.Set("X-API-Key", tt.header)
			}

			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)

			if rec.Code != tt.wantStatus {
				t.Errorf("status = %d, want %d", rec.Code, tt.wantStatus)
			}
			if called != tt.wantNextCall {
				t.Errorf("next handler called = %v, want %v", called, tt.wantNextCall)
			}
		})
	}
}
