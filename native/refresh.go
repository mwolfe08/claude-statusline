package main

import (
	"encoding/json"
	"html"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

// Background mode: refresh whatever cache is stale and rewrite it, then exit without
// rendering (no stdin read). Each block fails soft -- a stale cache is left untouched
// on any error, and the failure is recorded so the negative cache can back off.
//
// Timeouts here are generous precisely BECAUSE they run off the render hot path.
const fetchTimeout = 6 * time.Second

// dotNetRoundTripStamp is (Get-Date).ToString('o'). Nothing reads it back -- the
// caches are aged by file mtime -- but the shape is kept so a human eyeballing a
// cache file sees what they saw before.
func dotNetRoundTripStamp(t time.Time) string {
	return t.Format("2006-01-02T15:04:05.0000000-07:00")
}

// writeJSONCache writes a cache file as UTF-8 WITH a BOM.
//
// The BOM is REQUIRED, not cosmetic. PowerShell's `Set-Content -Encoding UTF8` emits one
// under 5.1 (verified by hexdump on all four live JSON caches), and 5.1's `Get-Content
// -Raw` decodes a BOM-LESS file using the ANSI codepage. Writing these without it means a
// rollback to statusline.ps1 reads back every curly quote as mojibake -- measured:
// U+201C came out as "a-circumflex, Euro, oe". Same trap family as the "no non-ASCII
// string literals in the script" rule in AGENTS.md.
//
// Only the JSON caches get one. windows.cache, the .series files, the transcript state
// and the refresh marker are written by PowerShell with -Encoding ASCII and carry no BOM,
// so adding one there would break the parsers instead of fixing them.
func writeJSONCache(path string, data []byte) error {
	out := make([]byte, 0, len(data)+3)
	out = append(out, 0xEF, 0xBB, 0xBF)
	out = append(out, data...)
	return os.WriteFile(path, out, 0o644)
}

func httpClient() *http.Client { return &http.Client{Timeout: fetchTimeout} }

func getBody(req *http.Request) ([]byte, error) {
	resp, err := httpClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, errStatus(resp.Status)
	}
	return io.ReadAll(resp.Body)
}

type errStatus string

func (e errStatus) Error() string { return string(e) }

func invokeCacheRefresh(cfg Config, p paths, id *identity) {
	refreshWeather(cfg, p)
	refreshUsage(p, id)
	refreshVerses(cfg, p)
}

func refreshWeather(cfg Config, p paths) {
	if cfg.WeatherLat == "" || cfg.WeatherLon == "" || !cacheDue(p.weatherCache, weatherMaxAge) {
		return
	}
	url := "https://api.open-meteo.com/v1/forecast?latitude=" + cfg.WeatherLat +
		"&longitude=" + cfg.WeatherLon +
		"&current=temperature_2m,weather_code,wind_speed_10m,wind_direction_10m" +
		"&daily=weather_code,precipitation_sum,wind_speed_10m_max,precipitation_probability_max" +
		"&temperature_unit=fahrenheit&wind_speed_unit=mph&timezone=auto&forecast_days=16"
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		setFetchFailed(p.weatherCache)
		return
	}
	body, err := getBody(req)
	if err != nil || !json.Valid(body) {
		setFetchFailed(p.weatherCache)
		return
	}
	// Store the response verbatim under "weather", exactly the shape the PowerShell
	// wrote, so either implementation can read a cache the other produced.
	out, err := json.Marshal(map[string]any{
		"fetched_at": dotNetRoundTripStamp(time.Now()),
		"weather":    json.RawMessage(body),
	})
	if err != nil {
		setFetchFailed(p.weatherCache)
		return
	}
	if writeJSONCache(p.weatherCache, out) != nil {
		setFetchFailed(p.weatherCache)
		return
	}
	clearFetchFailed(p.weatherCache)
}

func refreshUsage(p paths, id *identity) {
	if !id.usageRefetchDue() {
		return
	}
	raw, err := os.ReadFile(p.credPath)
	if err != nil {
		return
	}
	var creds struct {
		ClaudeAiOauth struct {
			AccessToken string `json:"accessToken"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(stripBOM(raw), &creds) != nil || creds.ClaudeAiOauth.AccessToken == "" {
		setFetchFailed(p.usageCache)
		return
	}
	auth := func(url string) *http.Request {
		req, _ := http.NewRequest("GET", url, nil)
		if req == nil {
			return nil
		}
		req.Header.Set("Authorization", "Bearer "+creds.ClaudeAiOauth.AccessToken)
		req.Header.Set("anthropic-beta", "oauth-2025-04-20")
		return req
	}
	body, err := getBody(auth("https://api.anthropic.com/api/oauth/usage"))
	if err != nil {
		setFetchFailed(p.usageCache)
		return
	}
	var doc map[string]json.RawMessage
	if json.Unmarshal(body, &doc) != nil {
		setFetchFailed(p.usageCache)
		return
	}
	// The profile call is best-effort: an empty _email must never hide quota, because
	// the identity guard treats "unknown" as "these numbers are this profile's own".
	email := ""
	if pbody, perr := getBody(auth("https://api.anthropic.com/api/oauth/profile")); perr == nil {
		var prof struct {
			Account struct {
				Email string `json:"email"`
			} `json:"account"`
		}
		if json.Unmarshal(pbody, &prof) == nil {
			email = prof.Account.Email
		}
	}
	enc, _ := json.Marshal(email)
	doc["_email"] = enc
	out, err := json.Marshal(doc)
	if err != nil || writeJSONCache(p.usageCache, out) != nil {
		setFetchFailed(p.usageCache)
		return
	}
	clearFetchFailed(p.usageCache)
}

// A disabled line must not be fetched either -- otherwise it keeps writing a cache
// nothing renders, and a broken one keeps burning its backoff retries.
func refreshVerses(cfg Config, p paths) {
	type job struct {
		cache string
		fetch func() *verse
	}
	var jobs []job
	if cfg.VerseBibleGateway {
		jobs = append(jobs, job{p.verseBGCache, fetchVerseBG})
	}
	if cfg.VerseYouVersion {
		jobs = append(jobs, job{p.verseYVCache, fetchVerseYV})
	}
	for _, j := range jobs {
		if !cacheDue(j.cache, verseMaxAge) {
			continue
		}
		fresh := j.fetch()
		if fresh == nil || fresh.Text == "" || fresh.Ref == "" {
			// Reached the endpoint but could not parse it -- the exact shape that spun
			// forever before. A soft null is a FAILURE, not a no-op.
			setFetchFailed(j.cache)
			continue
		}
		out, err := json.Marshal(map[string]any{
			"fetched_at": dotNetRoundTripStamp(time.Now()),
			"text":       fresh.Text,
			"ref":        fresh.Ref,
		})
		if err != nil || writeJSONCache(j.cache, out) != nil {
			setFetchFailed(j.cache)
			continue
		}
		clearFetchFailed(j.cache)
	}
}

var (
	htmlTag        = regexp.MustCompile(`<[^>]+>`)
	leadingQuotes  = regexp.MustCompile(`^[\s"\x{201C}\x{201D}]+`)
	trailingQuotes = regexp.MustCompile(`[\s"\x{201C}\x{201D}]+$`)
	ogDescription  = regexp.MustCompile(`<meta\s+property="og:description"\s+content="([^"]+)"`)
	// [\s\S] not . -- the description carries the verse's own line breaks
	// ("...to your light,\nand kings to..."), and an anchored `.` cannot cross one.
	yvVerse = regexp.MustCompile(`^((?:\d\s+)?[A-Za-z]+(?:\s+of\s+\w+)?)\s+(\d+:\d+(?:-\d+)?)\s+([\s\S]+)$`)
)

// curlyWrap trims stray quoting and re-wraps in typographic quotes, matching
// [char]0x201C + text + [char]0x201D.
func curlyWrap(s string) string {
	s = strings.TrimSpace(s)
	s = leadingQuotes.ReplaceAllString(s, "")
	s = trailingQuotes.ReplaceAllString(s, "")
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	return "“" + s + "”"
}

func fetchVerseBG() *verse {
	req, err := http.NewRequest("GET", "https://www.biblegateway.com/votd/get/?format=json&version=ESV", nil)
	if err != nil {
		return nil
	}
	body, err := getBody(req)
	if err != nil {
		return nil
	}
	var doc struct {
		Votd struct {
			Text      string `json:"text"`
			Reference string `json:"reference"`
		} `json:"votd"`
	}
	if json.Unmarshal(body, &doc) != nil {
		return nil
	}
	t := html.UnescapeString(doc.Votd.Text)
	t = strings.TrimSpace(htmlTag.ReplaceAllString(t, ""))
	t = curlyWrap(t)
	if t == "" {
		return nil
	}
	return &verse{Text: t, Ref: doc.Votd.Reference + " ESV, Bible Gateway"}
}

// fetchVerseYV: NO QUERY STRING. `?version=59` (ESV) returns a 3 KB bot-protection
// interstitial titled "Client Challenge" instead of the page -- that is what silently
// killed this fetcher (the cache went 31h stale before anyone noticed, 2026-08-06).
// The bare URL is still edge-served and returns the real page with og:description
// intact.
//
// COST OF THE FIX: the bare URL serves YouVersion's default translation, NIV, not ESV
// -- and there is no way back to ESV here. A cookie does not change it, and every
// parameterised form trips the same challenge. No keyless ESV verse-of-the-day API
// exists (licensing); Bible Gateway ESV already covers the other line. So this line is
// LABELLED NIV rather than pretending to be ESV.
func fetchVerseYV() *verse {
	req, err := http.NewRequest("GET", "https://www.bible.com/verse-of-the-day", nil)
	if err != nil {
		return nil
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36")
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	body, err := getBody(req)
	if err != nil {
		return nil
	}
	m := ogDescription.FindStringSubmatch(string(body))
	if m == nil {
		return nil
	}
	content := html.UnescapeString(m[1])
	v := yvVerse.FindStringSubmatch(content)
	if v == nil {
		return nil
	}
	vt := curlyWrap(whitespaceRun.ReplaceAllString(v[3], " "))
	if vt == "" {
		return nil
	}
	return &verse{Text: vt, Ref: v[1] + " " + v[2] + " NIV, YouVersion"}
}
