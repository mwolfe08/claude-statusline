package main

import (
	"encoding/json"
	"os"
	"time"
)

// usageDoc is the subset of the undocumented /api/oauth/usage response the status
// line renders, plus the _email stamp the refresher adds.
//
// Pointers where the original tested `-ne $null`: an ABSENT utilization and a zero
// utilization render differently (nothing vs "5h 0%"), so the distinction has to
// survive parsing.
type usageDoc struct {
	FiveHour struct {
		Utilization *float64 `json:"utilization"`
		ResetsAt    string   `json:"resets_at"`
	} `json:"five_hour"`
	SevenDay struct {
		Utilization *float64 `json:"utilization"`
		ResetsAt    string   `json:"resets_at"`
	} `json:"seven_day"`
	// Model-scoped weekly limits (e.g. Fable) live ONLY here -- there is NO top-level
	// utilization key for them like five_hour/seven_day.
	Limits []struct {
		Kind    string   `json:"kind"`
		Percent *float64 `json:"percent"`
		Scope   *struct {
			Model *struct {
				DisplayName string `json:"display_name"`
			} `json:"model"`
		} `json:"scope"`
	} `json:"limits"`
	Email string `json:"_email"`
}

func readUsageCache(path string) (usageDoc, bool) {
	var u usageDoc
	raw, err := os.ReadFile(path)
	if err != nil {
		return u, false
	}
	if json.Unmarshal(stripBOM(raw), &u) != nil {
		return u, false
	}
	return u, true
}

// parseDotNetTime is [datetime]::Parse(s) for the ISO-8601 stamps in these caches:
// it accepts the offset forms the API emits and returns LOCAL time, which is what
// .NET's Parse does with an offset-bearing string and what every consumer here
// assumes (the reset arrows print a local clock).
func parseDotNetTime(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	for _, layout := range []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02T15:04:05.999999999",
		"2006-01-02T15:04:05",
		"2006-01-02 15:04:05",
	} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.Local(), true
		}
	}
	return time.Time{}, false
}

// stripBOM tolerates the UTF-8 BOM that PowerShell's `Set-Content -Encoding UTF8`
// writes. Every cache these two implementations share can have been written by
// either one, so both directions have to read the other's bytes.
func stripBOM(b []byte) []byte {
	if len(b) >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF {
		return b[3:]
	}
	return b
}
