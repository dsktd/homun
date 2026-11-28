package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

// A device is one remote client with its own key and permissions, kept as devices/<name>.json,
// written by `homun cockpit device add` on the host. Only the key's SHA-256 is stored. The
// files are read on every request, so a `device del` refuses the device at once.

var deviceName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

type Device struct {
	Name     string `json:"name"`
	Hash     string `json:"sha256"`
	Created  int64  `json:"created"`
	Secrets  bool   `json:"secrets"`  // may send secret-widget values
	Approve  bool   `json:"approve"`  // may answer permission prompts
	ReadOnly bool   `json:"readonly"` // may only read the stream
	Alarms   bool   `json:"alarms"`   // gets alarms to the user even when not last active
}

type Devices struct{ dir string }

func (d Devices) path(name string) string { return filepath.Join(d.dir, name+".json") }

func hashKey(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

func (d Devices) List() []Device {
	files, _ := filepath.Glob(filepath.Join(d.dir, "*.json"))
	sort.Strings(files)
	var out []Device
	for _, f := range files {
		var dev Device
		if body, err := os.ReadFile(f); err == nil && json.Unmarshal(body, &dev) == nil && deviceName.MatchString(dev.Name) {
			out = append(out, dev)
		}
	}
	return out
}

// Check returns the device whose key KEY is, comparing every hash in constant time.
func (d Devices) Check(key string) (Device, bool) {
	if key == "" {
		return Device{}, false
	}
	want := []byte(hashKey(key))
	var hit Device
	found := false
	for _, dev := range d.List() {
		if subtle.ConstantTimeCompare(want, []byte(dev.Hash)) == 1 {
			hit, found = dev, true
		}
	}
	return hit, found
}

func writeAtomic(path string, body []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	os.Chmod(tmp.Name(), 0o600)
	return os.Rename(tmp.Name(), path)
}
