package main

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func up(s *Server, key, name, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", "/upload?name="+name, strings.NewReader(body))
	if key != "" {
		req.Header.Set("X-Homun-Key", key)
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

func upSetup(t *testing.T) (*Server, string, string) {
	s, key, home := setup(t)
	s.uploads = filepath.Join(home, "up")
	s.uploadMax = 10
	return s, key, home
}

func TestUploadRefusedWithoutKey(t *testing.T) {
	s, _, _ := upSetup(t)
	if rec := up(s, "nope", "a.txt", "hi"); rec.Code != 401 {
		t.Fatalf("got %d", rec.Code)
	}
	if _, err := os.Stat(s.uploads); err == nil {
		t.Fatal("a refused upload must write nothing")
	}
}

func TestUploadSavesMode600(t *testing.T) {
	s, key, _ := upSetup(t)
	rec := up(s, key, "a.txt", "hi")
	if rec.Code != 200 {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
	files, _ := filepath.Glob(filepath.Join(s.uploads, "phone", "*-a.txt"))
	if len(files) != 1 {
		t.Fatalf("saved: %v", files)
	}
	if fi, _ := os.Stat(files[0]); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}
	if !strings.Contains(rec.Body.String(), files[0]) {
		t.Fatalf("reply %s lacks the path", rec.Body)
	}
}

func TestUploadSizeCap(t *testing.T) {
	s, key, _ := upSetup(t)
	if rec := up(s, key, "big.bin", strings.Repeat("x", 11)); rec.Code != 413 {
		t.Fatalf("got %d", rec.Code)
	}
	if files, _ := filepath.Glob(filepath.Join(s.uploads, "phone", "*")); len(files) != 0 {
		t.Fatalf("a refused upload left %v", files)
	}
}

func TestUploadTraversal(t *testing.T) {
	s, key, home := upSetup(t)
	for _, name := range []string{"..%2F..%2Fevil", "%2Fetc%2Fpasswd", "..%5C..%5Cevil", "%2E%2E%2Fx"} {
		up(s, key, name, "hi")
	}
	if rec := up(s, key, "..", "hi"); rec.Code != 400 {
		t.Fatalf(".. got %d", rec.Code)
	}
	if _, err := os.Stat(filepath.Join(home, "evil")); err == nil {
		t.Fatal("escaped the uploads directory")
	}
	filepath.Walk(s.uploads, func(p string, fi os.FileInfo, _ error) error {
		if !fi.IsDir() && filepath.Dir(p) != filepath.Join(s.uploads, "phone") {
			t.Errorf("%s is outside the device directory", p)
		}
		return nil
	})
	if got := safeName("../../.ssh/a b.png"); got != "a_b.png" {
		t.Fatalf("safeName: %q", got)
	}
}
