package main

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Stale-while-revalidate network cache. The render path NEVER blocks on the
// network: every network-backed detail (weather, subscription quota, verses) is
// served from a cache file, and when a cache goes stale the render fires a
// DETACHED background copy of this binary (-refresh-only) that refetches and
// rewrites the caches, then exits.
const (
	weatherMaxAge = 43200 // 12 hr
	usageMaxAge   = 300   // 5 min  (Anthropic rate-limits /api/oauth/usage hard)
	verseMaxAge   = 43200 // 12 hr

	// Negative cache. A fetcher that CANNOT succeed -- dead endpoint, changed
	// markup, bot challenge -- used to pin the refresh trigger permanently ON,
	// so one unfixable item made every active ACCOUNT spawn a refresh process
	// every 45s forever (found 2026-08-06: YouVersion's cache had been stale 31h
	// doing exactly that). Each failure bumps a count in <cache>.fail and the item
	// is not due again until an exponentially growing backoff elapses.
	failBase = 300   // 5 min after the first failure
	failCap  = 21600 // 6 hour ceiling
)

// paths bundles every file location the render and refresh paths share.
//
// Note which ones are canonical ~/.claude and which are the per-account
// CLAUDE_CONFIG_DIR -- they are deliberately different. Weather, verses, the
// transcript state and the cost tracker are machine-wide (cost is intentionally
// ONE pool across all accounts); the usage cache, credentials and refresh marker
// are per-account, because quota and identity are.
type paths struct {
	cfgDir       string // CLAUDE_CONFIG_DIR, else ~/.claude
	canonical    string // always ~/.claude
	weatherCache string
	usageCache   string
	credPath     string
	verseBGCache string
	verseYVCache string
	refreshMark  string
	txDir        string
	costDir      string
}

func resolvePaths() paths {
	home := os.Getenv("USERPROFILE")
	canonical := filepath.Join(home, ".claude")

	// The ccc/ccfg/ccg switcher exports CLAUDE_CONFIG_DIR, which even a -NoProfile
	// child inherits. Read the SESSION's own creds + usage from it so the account
	// tag and quota match the RUNNING account, not whichever canonical login is
	// current. Falls back to canonical for a plain `claude`.
	cfgDir := canonical
	if v := os.Getenv("CLAUDE_CONFIG_DIR"); v != "" {
		if st, err := os.Stat(v); err == nil && st.IsDir() {
			cfgDir = v
		}
	}
	return paths{
		cfgDir:       cfgDir,
		canonical:    canonical,
		weatherCache: filepath.Join(canonical, "weather-cache.json"),
		usageCache:   filepath.Join(cfgDir, "usage-exact.json"),
		credPath:     filepath.Join(cfgDir, ".credentials.json"),
		verseBGCache: filepath.Join(canonical, "verse-cache.json"),
		verseYVCache: filepath.Join(canonical, "verse-cache-yv.json"),
		refreshMark:  filepath.Join(cfgDir, "statusline-refresh.marker"),
		txDir:        filepath.Join(canonical, "transcript-cache"),
		costDir:      filepath.Join(canonical, "cost-tracker"),
	}
}

// cacheAge is Get-CacheAge: seconds since last write, or +Inf when absent.
func cacheAge(p string) float64 {
	st, err := os.Stat(p)
	if err != nil {
		return math.MaxFloat64
	}
	return time.Since(st.ModTime()).Seconds()
}

func failBackoff(p string) float64 {
	raw, err := os.ReadFile(p + ".fail")
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		n = 1
	}
	if n < 1 {
		n = 1
	}
	exp := n - 1
	if exp > 10 {
		exp = 10
	}
	return math.Min(failBase*math.Pow(2, float64(exp)), failCap)
}

// fetchAllowed = not inside a failure backoff window. Split out of cacheDue so a
// FORCE-refetch reason (see usageIdentityStale) can still honour the backoff
// without also having to be past its max age. Bypassing the backoff is exactly
// what pinned the refresh trigger permanently ON in the 2026-08-06 spin bug.
func fetchAllowed(p string) bool { return cacheAge(p+".fail") >= failBackoff(p) }

// cacheDue = past its max age AND not inside a failure backoff window.
func cacheDue(p string, maxAge float64) bool {
	if cacheAge(p) <= maxAge {
		return false
	}
	return fetchAllowed(p)
}

func setFetchFailed(p string) {
	n := 0
	if raw, err := os.ReadFile(p + ".fail"); err == nil {
		if v, err := strconv.Atoi(strings.TrimSpace(string(raw))); err == nil {
			n = v
		}
	}
	_ = os.WriteFile(p+".fail", []byte(strconv.Itoa(n+1)), 0o644)
}

func clearFetchFailed(p string) { _ = os.Remove(p + ".fail") }

// ---- IDENTITY GUARD ON THE USAGE CACHE ----
//
// The usage cache is written from whatever token sat in THIS profile's
// .credentials.json at fetch time, and usageMaxAge then holds it for 5 minutes. So
// a profile whose identity CHANGES -- a /login as a different account, a second
// team seat being set up -- keeps serving the PREVIOUS account's numbers until that
// expires, and does it under a correct-looking tag: the tag is resolved from the
// profile FOLDER while the numbers come from this file, two independent sources
// that disagree silently. Observed 2026-08-11 between two profiles signed in to two
// seats on ONE org: the second rendered the FIRST's percentages and reset times
// under its own correct tag.
//
// The two sides compared: _email is stamped into the cache from /api/oauth/profile
// using the SAME token that produced the numbers, so it names whose numbers these
// are; .claude.json names who this profile is signed in as NOW.
var emailRe = regexp.MustCompile(`"emailAddress"\s*:\s*"([^"]*)"`)

type identity struct {
	p      paths
	email  string
	loaded bool
}

// profileEmail is memoized -- both the refresh trigger and the render path ask
// for it, and .claude.json runs 50-250 KB here.
func (id *identity) profileEmail() string {
	if id.loaded {
		return id.email
	}
	id.loaded = true
	raw, err := os.ReadFile(filepath.Join(id.p.cfgDir, ".claude.json"))
	if err != nil {
		return ""
	}
	// Regex the oauthAccount block out of the raw text rather than parsing the
	// whole file as JSON.
	i := strings.Index(string(raw), `"oauthAccount"`)
	if i < 0 {
		return ""
	}
	end := i + 2000
	if end > len(raw) {
		end = len(raw)
	}
	if m := emailRe.FindStringSubmatch(string(raw[i:end])); m != nil {
		id.email = m[1]
	}
	return id.email
}

// usageIdentityStale is TRUE only when BOTH identities are known and they differ.
// An unknown on either side must never hide quota: /api/oauth/profile can fail and
// leave _email empty, and those numbers are still this profile's own.
func (id *identity) usageIdentityStale() bool {
	if _, err := os.Stat(id.p.usageCache); err != nil {
		return false
	}
	pe := id.profileEmail()
	if pe == "" {
		return false
	}
	raw, err := os.ReadFile(id.p.usageCache)
	if err != nil {
		return false
	}
	var probe struct {
		Email string `json:"_email"`
	}
	if json.Unmarshal(raw, &probe) != nil || probe.Email == "" {
		return false
	}
	return probe.Email != pe
}

func (id *identity) usageRefetchDue() bool {
	return cacheDue(id.p.usageCache, usageMaxAge) ||
		(id.usageIdentityStale() && fetchAllowed(id.p.usageCache))
}
