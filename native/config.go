package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

// Config is the CONFIG block of statusline.ps1, lifted OUT of the program text.
//
// In the PowerShell version lines 6-50 were personal values living inside the
// script, which is why `sync-live.ps1` had to exist: every code sync had to copy
// around them. A compiled binary cannot carry them at all -- and should not, since
// the public mirror ships the same bytes -- so they move to a JSON file beside the
// binary. The defaults below are the PUBLIC template values, byte-for-byte what the
// repo copy of statusline.ps1 carries, so a missing config file renders exactly what
// a fresh clone would.
type Config struct {
	// Open-Meteo coordinates. EITHER empty disables weather.
	WeatherLat string `json:"weather_lat"`
	WeatherLon string `json:"weather_lon"`

	// Account tag (row 3). ProfileTags is matched first, by CLAUDE_CONFIG_DIR
	// profile-folder name; AccountTags is the fallback, by email-domain suffix.
	// A 2nd seat on an org already in AccountTags MUST be listed in ProfileTags:
	// it shares the first seat's domain, so the fallback would resolve both to one
	// tag and the two sessions would be indistinguishable.
	ProfileTags map[string]string `json:"profile_tags"`
	AccountTags map[string]string `json:"account_tags"`

	// Cost chip (row 2). CostWindows=false renders only this session's figure and
	// skips the tracker entirely. BillingAnchorDay is the day of the month the plan
	// renews; the 30d window resets at 00:00 local on it.
	CostWindows      bool `json:"cost_windows"`
	BillingAnchorDay int  `json:"billing_anchor_day"`

	// Prompt-cache countdown (row 1). TTL is DETECTED from usage.cache_creation
	// when the API reports it; CacheTTLMin is the pre-write default and the manual
	// override for the undocumented 5-minute overage downgrade. 0 hides the chip.
	CacheTTLMin  int `json:"cache_ttl_min"`
	CacheWarnMin int `json:"cache_warn_min"`
	CacheCritMin int `json:"cache_crit_min"`

	// Verse lines. Bible Gateway serves ESV; YouVersion serves NIV and cannot be
	// pinned (see fetchVerseYV). Either can be disabled independently.
	VerseYouVersion   bool `json:"verse_youversion"`
	VerseBibleGateway bool `json:"verse_biblegateway"`
}

func defaultConfig() Config {
	return Config{
		WeatherLat:        "",
		WeatherLon:        "",
		ProfileTags:       map[string]string{},
		AccountTags:       map[string]string{"gmail.com": "me"},
		CostWindows:       true,
		BillingAnchorDay:  1,
		CacheTTLMin:       60,
		CacheWarnMin:      15,
		CacheCritMin:      6,
		VerseYouVersion:   true,
		VerseBibleGateway: true,
	}
}

// ConfigPath is canonical ~/.claude, NOT the per-account CLAUDE_CONFIG_DIR: the
// statusline command in settings.json names one absolute path shared by every
// profile, so its settings are per-machine, not per-account.
func configPath() string {
	if p := os.Getenv("STATUSLINE_CONFIG"); p != "" {
		return p
	}
	return filepath.Join(os.Getenv("USERPROFILE"), ".claude", "statusline-config.json")
}

// loadConfig fails soft in both directions: a missing file yields the public
// defaults, and a malformed one yields whatever fields parsed before the error.
// Nothing here may abort a render -- the whole script is $ErrorActionPreference
// SilentlyContinue by design.
func loadConfig() Config {
	c := defaultConfig()
	raw, err := os.ReadFile(configPath())
	if err != nil {
		return c
	}
	_ = json.Unmarshal(raw, &c)
	if c.ProfileTags == nil {
		c.ProfileTags = map[string]string{}
	}
	if c.AccountTags == nil {
		c.AccountTags = map[string]string{}
	}
	return c
}

// accountTagDomains returns the AccountTags keys longest-first. The PowerShell
// version iterated a hashtable, whose enumeration order is unspecified; for the
// real data (no domain is a suffix of another) any order gives the same answer,
// and longest-first additionally makes an overlapping pair resolve to the more
// specific domain instead of to whichever one enumerated first.
func (c Config) accountTagDomains() []string {
	out := make([]string, 0, len(c.AccountTags))
	for k := range c.AccountTags {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool {
		if len(out[i]) != len(out[j]) {
			return len(out[i]) > len(out[j])
		}
		return out[i] < out[j]
	})
	return out
}
