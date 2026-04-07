package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/subtle"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

var (
	dataDir string
	token   string
)

func main() {
	dataDir = env("GALLERY_DATA", "/srv/public")
	token = env("GALLERY_TOKEN", "")
	port := env("PORT", "8080")

	if token == "" {
		log.Fatal("GALLERY_TOKEN must be set")
	}

	os.MkdirAll(dataDir, 0755)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/sync/{name}", handleSync)
	mux.Handle("/", http.FileServer(http.Dir(dataDir)))

	log.Printf("gallery listening on :%s, serving %s", port, dataDir)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func handleSync(w http.ResponseWriter, r *http.Request) {
	if !checkAuth(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	name := r.PathValue("name")
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}

	// Extract to a temp directory, then atomic swap
	tmpDir, err := os.MkdirTemp(dataDir, ".tmp-"+name+"-")
	if err != nil {
		http.Error(w, "failed to create temp dir", http.StatusInternalServerError)
		return
	}
	defer os.RemoveAll(tmpDir) // cleanup on any error path

	if err := extractTarGz(r.Body, tmpDir); err != nil {
		http.Error(w, fmt.Sprintf("extract failed: %v", err), http.StatusBadRequest)
		return
	}

	liveDir := filepath.Join(dataDir, name)
	oldDir := tmpDir + ".old"

	// Atomic swap: rename live -> old, rename tmp -> live
	if _, err := os.Stat(liveDir); err == nil {
		if err := os.Rename(liveDir, oldDir); err != nil {
			http.Error(w, "swap failed", http.StatusInternalServerError)
			return
		}
		defer os.RemoveAll(oldDir)
	}

	if err := os.Rename(tmpDir, liveDir); err != nil {
		http.Error(w, "swap failed", http.StatusInternalServerError)
		return
	}

	log.Printf("synced %s", name)
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, "ok\n")
}

func extractTarGz(r io.Reader, dest string) error {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return fmt.Errorf("gzip: %w", err)
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("tar: %w", err)
		}

		// Sanitize path to prevent traversal
		clean := filepath.Clean(header.Name)
		if strings.HasPrefix(clean, "..") {
			continue
		}
		target := filepath.Join(dest, clean)

		switch header.Typeflag {
		case tar.TypeDir:
			os.MkdirAll(target, 0755)
		case tar.TypeReg:
			os.MkdirAll(filepath.Dir(target), 0755)
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(header.Mode))
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, io.LimitReader(tr, 50<<20)); err != nil { // 50MB per file limit
				f.Close()
				return err
			}
			f.Close()
		}
	}
	return nil
}

func checkAuth(r *http.Request) bool {
	auth := r.Header.Get("Authorization")
	expected := "Bearer " + token
	return subtle.ConstantTimeCompare([]byte(auth), []byte(expected)) == 1
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
