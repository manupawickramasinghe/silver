package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHealthHandler(t *testing.T) {
	req, err := http.NewRequest("GET", "/health", nil)
	if err != nil {
		t.Fatal(err)
	}

	rr := httptest.NewRecorder()
	handler := http.HandlerFunc(healthHandler)

	handler.ServeHTTP(rr, req)

	// Check the status code
	if status := rr.Code; status != http.StatusOK {
		t.Errorf("handler returned wrong status code: got %v want %v",
			status, http.StatusOK)
	}

	// Check the Content-Type header
	if contentType := rr.Header().Get("Content-Type"); contentType != "application/json" {
		t.Errorf("handler returned wrong content type: got %v want %v",
			contentType, "application/json")
	}

	// Check the response body
	var response map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &response); err != nil {
		t.Fatalf("failed to unmarshal response body: %v", err)
	}

	if response["status"] != "healthy" {
		t.Errorf("handler returned unexpected status: got %v want %v",
			response["status"], "healthy")
	}

	// Check if timestamp is a valid RFC3339 string
	if timestampStr, ok := response["timestamp"]; ok {
		if _, err := time.Parse(time.RFC3339, timestampStr); err != nil {
			t.Errorf("handler returned invalid timestamp format: %v", err)
		}
	} else {
		t.Errorf("handler response missing 'timestamp' field")
	}
}
