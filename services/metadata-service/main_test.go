package main

import (
	"os"
	"path/filepath"
	"testing"
)

func BenchmarkCreateHeartbeatPayload(b *testing.B) {
	// Setup
	tempDir, err := os.MkdirTemp("", "clamav-db-bench")
	if err != nil {
		b.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tempDir)

	// Save original and restore
	originalPath := config.ClamAVDBPath
	defer func() { config.ClamAVDBPath = originalPath }()
	config.ClamAVDBPath = tempDir

	// Create dummy daily.cvd file
	cvdPath := filepath.Join(tempDir, "daily.cvd")
	err = os.WriteFile(cvdPath, []byte("ClamAV-VDB:12345:100:"), 0644)
	if err != nil {
		b.Fatalf("failed to create dummy daily.cvd: %v", err)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := createHeartbeatPayload()
		if err != nil {
			b.Fatalf("createHeartbeatPayload failed: %v", err)
		}
	}
}
