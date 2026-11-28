package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func addPairing(t *testing.T, s *Server, id, secret, name string, expires time.Time) {
	t.Helper()
	os.MkdirAll(s.pairs.dir, 0o700)
	body, _ := json.Marshal(Pairing{Device: Device{Name: name, Hash: hashKey(secret), Approve: true}, Expires: expires.Unix()})
	os.WriteFile(s.pairs.path(id), body, 0o600)
}

func TestPairOnceAndReplaces(t *testing.T) {
	s, old, _ := setup(t)
	id := "abcdefghijklmnop"
	addPairing(t, s, id, "s3cret", "phone", time.Now().Add(10*time.Minute))
	if do(t, s, "", "GET", "/ca.crt", "").Code != 403 || doPair(s, "nope0000nope0000").Code != 403 {
		t.Fatal("bootstrap files need a key or a live pairing")
	}
	if rec := doPair(s, id); rec.Code != 404 { // 404: the test has no root certificate, but it is let in
		t.Fatalf("a live pairing id opens the certificate: %d", rec.Code)
	}
	rec := do(t, s, "", "POST", "/pair", `{"code":"`+id+`.s3cret"}`)
	var got struct {
		Device Device
		Key    string
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &got) != nil || got.Device.Name != "phone" || !got.Device.Approve {
		t.Fatalf("pair: %d %s", rec.Code, rec.Body)
	}
	if do(t, s, got.Key, "GET", "/snapshot", "").Code != 200 || do(t, s, old, "GET", "/snapshot", "").Code != 401 {
		t.Fatal("the new key works and replaces the old one of the name")
	}
	if do(t, s, "", "POST", "/pair", `{"code":"`+id+`.s3cret"}`).Code != 403 {
		t.Fatal("a code is single use")
	}
	if doPair(s, id).Code != 403 {
		t.Fatal("a used pairing opens nothing")
	}
}

func TestPairWrongOrExpired(t *testing.T) {
	s, _, _ := setup(t)
	addPairing(t, s, "wrongwrongwrong0", "right", "tab", time.Now().Add(time.Minute))
	addPairing(t, s, "expiredexpired00", "right", "tab", time.Now().Add(-time.Second))
	for _, code := range []string{"wrongwrongwrong0.bad", "wrongwrongwrong0.right", "expiredexpired00.right", "x", ""} {
		if rec := do(t, s, "", "POST", "/pair", `{"code":"`+code+`"}`); rec.Code != 403 || !strings.Contains(rec.Body.String(), "pairing") {
			t.Fatalf("%q must be refused: %d", code, rec.Code)
		}
	}
	if _, err := os.Stat(s.devices.path("tab")); err == nil {
		t.Fatal("no device from a refused code")
	}
}

func TestPairingPageOnlyWhileLive(t *testing.T) {
	s, _, _ := setup(t)
	os.MkdirAll(s.pairs.dir, 0o700)
	exp := time.Now().Add(time.Minute).Unix()
	os.WriteFile(s.pairs.path("abcdef0123456789"), []byte(fmt.Sprintf(`{"name":"phone","sha256":"%s","expires":%d}`, hashKey("sec"), exp)), 0o600)
	os.WriteFile(filepath.Join(s.pairs.dir, "abcdef0123456789.line"), []byte("(homun-remote-start \"x\")"), 0o600)
	if rec := do(t, s, "", "GET", "/p/abcdef0123456789", ""); rec.Code != 200 || !strings.Contains(rec.Body.String(), "homun-remote-start &#34;x&#34;") {
		t.Fatalf("live page: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do(t, s, "", "POST", "/pair", `{"code":"abcdef0123456789.sec"}`); rec.Code != 200 {
		t.Fatalf("redeem: %d", rec.Code)
	}
	if rec := do(t, s, "", "GET", "/p/abcdef0123456789", ""); rec.Code != 404 {
		t.Fatal("a used code has no page")
	}
}

func doPair(s *Server, id string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("GET", "/ca.crt", nil)
	req.Header.Set("X-Homun-Pair", id)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}
