package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestApiKeyAuthMiddleware(t *testing.T) {
	// A dummy handler to represent our protected endpoint
	dummyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"success": true}`))
	})

	// Wrap the dummy handler with our middleware
	handlerUnderTest := apiKeyAuthMiddleware(dummyHandler)

	t.Run("API Key Not Configured", func(t *testing.T) {
		// Save original config to restore later
		origAPIKey := config.APIKey
		defer func() { config.APIKey = origAPIKey }()

		// Unset the API key configuration
		config.APIKey = ""

		req := httptest.NewRequest("GET", "/test", nil)
		rr := httptest.NewRecorder()

		handlerUnderTest.ServeHTTP(rr, req)

		if status := rr.Code; status != http.StatusInternalServerError {
			t.Errorf("handler returned wrong status code: got %v want %v", status, http.StatusInternalServerError)
		}

		var response map[string]string
		if err := json.NewDecoder(rr.Body).Decode(&response); err != nil {
			t.Fatalf("could not decode response body: %v", err)
		}

		if response["error"] != "Server misconfiguration: API key not configured" {
			t.Errorf("handler returned unexpected error message: %v", response["error"])
		}
	})

	t.Run("Missing X-API-Key Header", func(t *testing.T) {
		origAPIKey := config.APIKey
		defer func() { config.APIKey = origAPIKey }()
		config.APIKey = "secret123"

		req := httptest.NewRequest("GET", "/test", nil)
		// Don't set X-API-Key header
		rr := httptest.NewRecorder()

		handlerUnderTest.ServeHTTP(rr, req)

		if status := rr.Code; status != http.StatusUnauthorized {
			t.Errorf("handler returned wrong status code: got %v want %v", status, http.StatusUnauthorized)
		}
	})

	t.Run("Invalid X-API-Key Header", func(t *testing.T) {
		origAPIKey := config.APIKey
		defer func() { config.APIKey = origAPIKey }()
		config.APIKey = "secret123"

		req := httptest.NewRequest("GET", "/test", nil)
		req.Header.Set("X-API-Key", "wrong-secret")
		rr := httptest.NewRecorder()

		handlerUnderTest.ServeHTTP(rr, req)

		if status := rr.Code; status != http.StatusUnauthorized {
			t.Errorf("handler returned wrong status code: got %v want %v", status, http.StatusUnauthorized)
		}
	})

	t.Run("Valid X-API-Key Header", func(t *testing.T) {
		origAPIKey := config.APIKey
		defer func() { config.APIKey = origAPIKey }()
		config.APIKey = "secret123"

		req := httptest.NewRequest("GET", "/test", nil)
		req.Header.Set("X-API-Key", "secret123")
		rr := httptest.NewRecorder()

		handlerUnderTest.ServeHTTP(rr, req)

		if status := rr.Code; status != http.StatusOK {
			t.Errorf("handler returned wrong status code: got %v want %v", status, http.StatusOK)
		}
	})
}