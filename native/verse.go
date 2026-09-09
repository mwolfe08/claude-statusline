package main

import (
	"encoding/json"
	"math/rand"
	"os"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Verse of the Day -- Bible Gateway (ESV) + YouVersion (NIV; see fetchVerseYV for
// why ESV is no longer reachable there), served from cache ONLY. Read BEFORE row 1
// is assembled, purely so row 1 can know whether a reference line will exist to
// carry the weather chips. Do not move these reads down into the verse block -- that
// reintroduces the vanishing-weather bug.
type verse struct {
	Text string `json:"text"`
	Ref  string `json:"ref"`
}

// versePalette is the brown range the words are tinted from, one random pick per
// word. LORD/God/Jesus/Lord override to red.
var versePalette = [10]int{52, 94, 95, 130, 131, 136, 137, 138, 143, 180}

// Case-SENSITIVE by design (the PowerShell used -cmatch): "lord" in ordinary prose
// must not be tinted as the divine name.
var divineName = regexp.MustCompile(`^(God|Jesus|LORD|Lord)([^A-Za-z].*)?$`)

var whitespaceRun = regexp.MustCompile(`\s+`)

func readVerseCache(cacheFile string) *verse {
	raw, err := os.ReadFile(cacheFile)
	if err != nil {
		return nil
	}
	var v verse
	if json.Unmarshal(stripBOM(raw), &v) != nil {
		return nil
	}
	return &v
}

// formatVerse wraps and colors one verse. suffix is appended to the REFERENCE line
// (the last line) -- that is where the weather chips ride, so the bottom line reads
// "<ref> | <weather> | <forecast>".
//
// Word lengths are counted in RUNES, matching PowerShell's UTF-16 .Length for every
// character these verses contain (all BMP: curly quotes, letters, punctuation).
func formatVerse(v *verse, wrapAt int, rnd *rand.Rand, suffix string) []string {
	words := splitWhitespace(v.Text)
	var lines []string
	cur := ""
	curLen := 0
	for _, w := range words {
		wl := utf8.RuneCountInString(w)
		switch {
		case curLen == 0:
			cur, curLen = w, wl
		case curLen+1+wl <= wrapAt:
			cur += " " + w
			curLen += 1 + wl
		default:
			lines = append(lines, cur)
			cur, curLen = w, wl
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}

	out := make([]string, 0, len(lines)+1)
	for _, line := range lines {
		var colored []string
		for _, w := range splitWhitespace(line) {
			if divineName.MatchString(w) {
				colored = append(colored, esc+"[31m"+w+reset)
			} else {
				c := versePalette[rnd.Intn(len(versePalette))]
				colored = append(colored, esc+"[38;5;"+strconv.Itoa(c)+"m"+w+reset)
			}
		}
		out = append(out, strings.Join(colored, " "))
	}
	refLine := magenta + v.Ref + reset
	if suffix != "" {
		refLine += suffix
	}
	return append(out, refLine)
}

// splitWhitespace is `-split '\s+' | Where-Object { $_ }` -- split on runs of
// whitespace, dropping the empty leading field a leading space would produce.
func splitWhitespace(s string) []string {
	parts := whitespaceRun.Split(s, -1)
	out := parts[:0]
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
