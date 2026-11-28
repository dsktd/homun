package main

import "testing"

// The transcript's markdown faces come from markdown-mode: without it a phone shows raw markdown.
func TestClientDepsCarryMarkdownMode(t *testing.T) {
	for _, d := range clientDeps {
		if d == "markdown-mode" {
			return
		}
	}
	t.Fatal("markdown-mode missing from clientDeps")
}
