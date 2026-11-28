package main

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func dl(s *Server, key, name string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("GET", "/download?name="+name, nil)
	if key != "" {
		req.Header.Set("X-Homun-Key", key)
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

func dlSetup(t *testing.T) (*Server, string, string) {
	s, key, home := setup(t)
	s.downloads = filepath.Join(home, "dl")
	s.downloadMax = 10
	os.MkdirAll(s.downloads, 0o755)
	os.WriteFile(filepath.Join(s.downloads, "a.apk"), []byte("hello"), 0o644)
	os.WriteFile(filepath.Join(s.downloads, "big.bin"), []byte("12345678901"), 0o644)
	os.WriteFile(filepath.Join(home, "secret"), []byte("s"), 0o644)
	os.Symlink(filepath.Join(home, "secret"), filepath.Join(s.downloads, "link"))
	return s, key, home
}

func TestDownloadNeedsKey(t *testing.T) {
	s, _, _ := dlSetup(t)
	if rec := dl(s, "nope", "a.apk"); rec.Code != 401 {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestDownloadServesFile(t *testing.T) {
	s, key, _ := dlSetup(t)
	rec := dl(s, key, "a.apk")
	if rec.Code != 200 || rec.Body.String() != "hello" {
		t.Fatalf("got %d %q", rec.Code, rec.Body)
	}
}

func TestDownloadRefusals(t *testing.T) {
	s, key, _ := dlSetup(t)
	for name, want := range map[string]int{
		"..%2Fsecret": 400, "%2Fetc%2Fpasswd": 400, "sub%2Fa.apk": 400, "..": 400, ".hid": 400, "": 400,
		"link": 404, "missing": 404, "big.bin": 413,
	} {
		if rec := dl(s, key, name); rec.Code != want {
			t.Errorf("%q: got %d, want %d", name, rec.Code, want)
		}
	}
}

func TestDownloadGetOnly(t *testing.T) {
	s, key, _ := dlSetup(t)
	req := httptest.NewRequest("POST", "/download?name=a.apk", nil)
	req.Header.Set("X-Homun-Key", key)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != 405 {
		t.Fatalf("got %d", rec.Code)
	}
}
