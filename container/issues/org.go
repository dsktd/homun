package main

// A small, safe subset of org-mode rendered to HTML. Every piece of text goes
// through html.EscapeString; nothing from the source is ever emitted raw.

import (
	"html"
	"html/template"
	"regexp"
	"strings"
)

var (
	inlineRe = regexp.MustCompile(`\[\[([^\]]+)\](?:\[([^\]]+)\])?\]|\*([^\s*][^*]*?)\*|/([^\s/][^/]*?)/|_([^\s_][^_]*?)_|[=~]([^\s=~][^=~]*?)[=~]`)
	bulletRe = regexp.MustCompile(`^\s*(?:[-+]|\d+[.)])\s+(.*)$`)
	boxRe    = regexp.MustCompile(`^\[([ Xx-])\]\s+`)
	idRe     = regexp.MustCompile(`^#?(\d+)$`)
	drawerRe = regexp.MustCompile(`^\s*:[A-Za-z_]+:\s*$`)
)

func esc(s string) string { return html.EscapeString(s) }

// href returns the link target for an org link, or "" when it is not allowed.
func href(t string) string {
	t = strings.TrimSpace(t)
	if m := idRe.FindStringSubmatch(t); m != nil {
		return m[1]
	}
	l := strings.ToLower(t)
	if strings.HasPrefix(l, "http://") || strings.HasPrefix(l, "https://") || strings.HasPrefix(l, "mailto:") {
		return t
	}
	return ""
}

func inline(s string) string {
	var b strings.Builder
	for {
		m := inlineRe.FindStringSubmatchIndex(s)
		if m == nil {
			b.WriteString(esc(s))
			return b.String()
		}
		b.WriteString(esc(s[:m[0]]))
		g := func(i int) string {
			if m[2*i] < 0 {
				return ""
			}
			return s[m[2*i]:m[2*i+1]]
		}
		switch {
		case m[2] >= 0:
			text := g(2)
			if text == "" {
				text = g(1)
			}
			if h := href(g(1)); h != "" {
				b.WriteString(`<a href="` + esc(h) + `">` + esc(text) + `</a>`)
			} else {
				b.WriteString(esc(text))
			}
		case g(3) != "":
			b.WriteString("<b>" + esc(g(3)) + "</b>")
		case g(4) != "":
			b.WriteString("<i>" + esc(g(4)) + "</i>")
		case g(5) != "":
			b.WriteString("<u>" + esc(g(5)) + "</u>")
		default:
			b.WriteString("<code>" + esc(g(6)) + "</code>")
		}
		s = s[m[1]:]
	}
}

func renderOrg(src string) template.HTML {
	lines := strings.Split(strings.ReplaceAll(src, "\r", ""), "\n")
	var b strings.Builder
	var para []string
	flush := func() {
		if len(para) > 0 {
			b.WriteString("<p>" + inline(strings.Join(para, " ")) + "</p>\n")
			para = nil
		}
	}
	for i := 0; i < len(lines); i++ {
		l := lines[i]
		t := strings.TrimSpace(l)
		up := strings.ToUpper(t)
		switch {
		case t == "":
			flush()
		case strings.HasPrefix(up, "#+BEGIN_"):
			flush()
			kind := strings.Fields(up[len("#+BEGIN_"):])[0]
			end := "#+END_" + kind
			var body []string
			for i++; i < len(lines) && !strings.HasPrefix(strings.ToUpper(strings.TrimSpace(lines[i])), end); i++ {
				body = append(body, lines[i])
			}
			if kind == "QUOTE" {
				b.WriteString("<blockquote>" + inline(strings.Join(strings.Fields(strings.Join(body, "\n")), " ")) + "</blockquote>\n")
			} else {
				// SRC, EXAMPLE and anything unknown (EXPORT included): escaped pre
				b.WriteString("<pre>" + esc(strings.Join(body, "\n")) + "</pre>\n")
			}
		case strings.HasPrefix(t, "#+"):
			flush()
		case drawerRe.MatchString(l):
			flush()
			if strings.ToUpper(t) != ":END:" {
				for i++; i < len(lines) && strings.ToUpper(strings.TrimSpace(lines[i])) != ":END:"; i++ {
				}
			}
		case strings.HasPrefix(t, "|"):
			flush()
			b.WriteString("<table>\n")
			for ; i < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[i]), "|"); i++ {
				row := strings.TrimSpace(lines[i])
				if strings.HasPrefix(row, "|-") {
					continue
				}
				b.WriteString("<tr>")
				for _, c := range strings.Split(strings.Trim(row, "|"), "|") {
					b.WriteString("<td>" + inline(strings.TrimSpace(c)) + "</td>")
				}
				b.WriteString("</tr>\n")
			}
			i--
			b.WriteString("</table>\n")
		case bulletRe.MatchString(l):
			flush()
			b.WriteString("<ul>\n")
			for ; i < len(lines); i++ {
				m := bulletRe.FindStringSubmatch(lines[i])
				if m == nil {
					c := strings.TrimSpace(lines[i])
					if c == "" || strings.HasPrefix(c, "#+") || !strings.HasPrefix(lines[i], " ") {
						break
					}
					b.WriteString(" " + inline(c))
					continue
				}
				if i > 0 && !strings.HasSuffix(b.String(), "\n") {
					b.WriteString("</li>\n")
				}
				item, box := m[1], ""
				if x := boxRe.FindStringSubmatch(item); x != nil {
					item = item[len(x[0]):]
					box = "[ ] "
					if x[1] != " " {
						box = "[x] "
					}
				}
				b.WriteString("<li>" + esc(box) + inline(item))
			}
			b.WriteString("</li>\n</ul>\n")
			i--
		default:
			para = append(para, t)
		}
	}
	flush()
	return template.HTML(b.String())
}
