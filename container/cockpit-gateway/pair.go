package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Pairing (design 3.6b): the desktop cockpit's "Pair phone" writes pair/<id>.json, holding the
// device name, its permissions, the SHA-256 of a secret and an expiry 10 minutes ahead. The
// phone's pairing code is <id>.<secret>. The id alone, while the pairing is live, opens /ca.crt
// for the bootstrap; the whole code, once, is exchanged at POST /pair for a new
// device key, which replaces any key the name had. A pairing is claimed by renaming it before
// it is checked, so a code is used at most once, and a wrong secret uses it up too.

var pairID = regexp.MustCompile(`^[a-z0-9]{16,32}$`)

type Pairing struct {
	Device
	Expires int64 `json:"expires"`
}

type Pairings struct {
	dir     string
	devices Devices
	now     func() time.Time
}

var errPair = errors.New("unknown, used or expired pairing code")

func (p Pairings) path(id string) string { return filepath.Join(p.dir, id+".json") }

func (p Pairings) read(file string) (Pairing, bool) {
	var pr Pairing
	body, err := os.ReadFile(file)
	if err != nil || json.Unmarshal(body, &pr) != nil || !deviceName.MatchString(pr.Name) || pr.Name == "host" {
		return pr, false
	}
	return pr, p.now().Unix() < pr.Expires
}

// Live reports whether ID names a pairing that has not expired; an expired one is removed.
func (p Pairings) Live(id string) bool {
	if !pairID.MatchString(id) {
		return false
	}
	_, ok := p.read(p.path(id))
	if !ok {
		os.Remove(p.path(id))
	}
	return ok
}

// Redeem claims the pairing of CODE and writes its device with a new key, which it returns.
func (p Pairings) Redeem(code string) (Device, string, error) {
	id, secret, _ := strings.Cut(code, ".")
	if !pairID.MatchString(id) || secret == "" {
		return Device{}, "", errPair
	}
	os.Remove(filepath.Join(p.dir, id+".line")) // the page goes with the first try
	claimed := p.path(id) + ".used"
	if os.Rename(p.path(id), claimed) != nil {
		return Device{}, "", errPair
	}
	defer os.Remove(claimed)
	pr, ok := p.read(claimed)
	if !ok || subtle.ConstantTimeCompare([]byte(hashKey(secret)), []byte(pr.Hash)) != 1 {
		return Device{}, "", errPair
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return Device{}, "", err
	}
	key := hex.EncodeToString(raw)
	dev := pr.Device
	dev.Hash, dev.Created = hashKey(key), p.now().Unix()
	body, _ := json.Marshal(dev)
	if err := os.MkdirAll(p.devices.dir, 0o700); err != nil {
		return Device{}, "", err
	}
	if err := writeAtomic(p.devices.path(dev.Name), body); err != nil {
		return Device{}, "", err
	}
	return dev, key, nil
}

// Line is the init.el text the desktop left for the live pairing ID (pair/<id>.line), for the
// pairing page; an expired pairing's line is removed.
func (p Pairings) Line(id string) (string, bool) {
	if !p.Live(id) {
		os.Remove(filepath.Join(p.dir, id+".line"))
		return "", false
	}
	body, err := os.ReadFile(filepath.Join(p.dir, id+".line"))
	return string(body), err == nil
}
