// The bus (stage 5): each role has <root>/.services/bus/<role>/ with inbox.jsonl (one JSON
// message per line, appended by homun-msg) and user/<device>/ (the user's words, one file per
// message, written by the cockpit). This server reads both for its own role's session.
package main

import (
	"os"
	"path/filepath"
	"strconv"
)

// busRole is the role whose bus this session reads.
func busRole() string {
	if r := os.Getenv("CLAUDE_ROLE"); r != "" {
		return r
	}
	if r := os.Getenv("HOMUN_PRIMARY"); r != "" {
		return r
	}
	return "manager"
}

func primaryRole() bool {
	p := os.Getenv("HOMUN_PRIMARY")
	if p == "" {
		p = "manager"
	}
	return busRole() == p
}

// busDir is bus/<role>/ ($HOMUN_BUS_DIR overrides the bus root).
func busDir() string {
	root := os.Getenv("HOMUN_BUS_DIR")
	if root == "" {
		home, _ := os.UserHomeDir()
		root = filepath.Join(home, "claude/.services/bus")
	}
	return filepath.Join(root, busRole())
}

// roleSession says whether the Claude Code that spawned this server is the role's own session:
// a direct child of start.sh (CLAUDE_ROLE_PID), or one compact-relay hop below it. A `claude -p`
// started from a shell inside the session does not qualify, so it never takes the role's mail.
func roleSession() bool {
	root, _ := strconv.Atoi(os.Getenv("CLAUDE_ROLE_PID"))
	if root <= 0 {
		return false
	}
	parent := parentPID(os.Getppid())
	if parent == root {
		return true
	}
	return isCompactRelay(parent) && parentPID(parent) == root
}

// writeAtomic replaces path with data through a temp file in the same directory.
func writeAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-")
	if err != nil {
		return err
	}
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr != nil || cerr != nil {
		os.Remove(tmp.Name())
		if werr != nil {
			return werr
		}
		return cerr
	}
	return os.Rename(tmp.Name(), path)
}
