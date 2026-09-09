package main

import (
	"bufio"
	"encoding/json"
	"io"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// payload is the JSON Claude Code pipes to the status line command on stdin.
//
// Pointers on the cost fields: the original distinguished an ABSENT figure from a
// zero one (`-ne $null`), and the two render differently -- a missing
// total_api_duration_ms falls back to total_duration_ms, while a zero one does not.
type payload struct {
	SessionID string `json:"session_id"`
	Model     struct {
		DisplayName string `json:"display_name"`
		ID          string `json:"id"`
	} `json:"model"`
	Workspace struct {
		CurrentDir string `json:"current_dir"`
	} `json:"workspace"`
	Cwd            string `json:"cwd"`
	TranscriptPath string `json:"transcript_path"`
	OutputStyle    struct {
		Name string `json:"name"`
	} `json:"output_style"`
	Cost struct {
		TotalCostUSD       *float64 `json:"total_cost_usd"`
		TotalDurationMs    *float64 `json:"total_duration_ms"`
		TotalAPIDurationMs *float64 `json:"total_api_duration_ms"`
	} `json:"cost"`
}

// Model-label rewrites, applied in order. All case-insensitive, matching
// PowerShell's -replace default.
var (
	strip1MSuffix = regexp.MustCompile(`(?i)\s*\(1M context\)\s*$`)
	modelShorten  = []struct {
		re   *regexp.Regexp
		with string
	}{
		{regexp.MustCompile(`(?i)^Opus\s+`), "Op"},
		{regexp.MustCompile(`(?i)^Sonnet\s+`), "So"},
		{regexp.MustCompile(`(?i)^Haiku\s+`), "Ha"},
		{regexp.MustCompile(`(?i)^Fable\s+`), "F"},
		{regexp.MustCompile(`(?i)^DeepSeek[\s-]*V?4[\s-]*Flash`), "DS4F"},
		{regexp.MustCompile(`(?i)^glm-5\.2:cloud(\[1m\])?$`), "glm5.2"},
	}

	// 1M context detection -- an id like "claude-opus-4-7[1m]" carries an explicit
	// marker (e.g. GLM); current-gen Anthropic models default to 1M with NO marker.
	oneMillion = regexp.MustCompile(`(?i)\[1m\]|-1m\b|fable|mythos|opus-4-[678]|sonnet-4-6|sonnet-5`)

	// Gate cost/quota/cache to real Anthropic sessions only. Local models (Ollama)
	// will not have an Anthropic model name. This is the ONLY gate -- do not layer
	// additional null checks on top that can kill the block even when it is true.
	anthropicName = regexp.MustCompile(`(?i)^Opus|^Sonnet|^Haiku|^Fable|^Mythos|^claude-`)
	anthropicID   = regexp.MustCompile(`(?i)claude-|anthropic-opus|anthropic-sonnet|anthropic-haiku|anthropic-fable`)
)

func main() {
	refreshOnly := false
	for _, a := range os.Args[1:] {
		switch strings.ToLower(a) {
		case "-refreshonly", "--refreshonly", "-refresh-only", "--refresh-only", "/refreshonly":
			refreshOnly = true
		}
	}

	cfg := loadConfig()
	p := resolvePaths()
	id := &identity{p: p}

	// Background mode: refresh stale caches, then EXIT without rendering (no stdin read).
	if refreshOnly {
		invokeCacheRefresh(cfg, p, id)
		return
	}

	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()

	render(cfg, p, id, out)
}

// emit writes one status line. CRLF, no BOM -- byte-for-byte what PowerShell's
// Write-Output produced on this host.
func emit(w *bufio.Writer, s string) {
	w.WriteString(s)
	w.WriteString("\r\n")
}

func render(cfg Config, p paths, id *identity, w *bufio.Writer) {
	// Normal render mode: if any cache is stale, launch ONE detached background
	// refresh (throttled per-account to ~45s), then fall straight through to render
	// from cache. cacheDue, not raw cacheAge: an item inside its failure backoff is
	// NOT due, so a permanently-broken fetcher can no longer hold this OR true and
	// respawn a refresh process every 45s in every account for ever.
	//
	// The weather arm carries the SAME coordinate guard refreshWeather has. Without it,
	// an install with blank coords can never write the weather cache, so it is
	// permanently due and this trigger spawns a detached refresh every 45 s for ever
	// that then does nothing -- the exact spin the negative cache was added to kill,
	// reachable through the one arm the backoff cannot cover, because a fetch that is
	// never attempted never records a failure. Fixed 2026-09-09 in both builds.
	if (cfg.WeatherLat != "" && cfg.WeatherLon != "" && cacheDue(p.weatherCache, weatherMaxAge)) ||
		id.usageRefetchDue() ||
		(cfg.VerseBibleGateway && cacheDue(p.verseBGCache, verseMaxAge)) ||
		(cfg.VerseYouVersion && cacheDue(p.verseYVCache, verseMaxAge)) {
		if cacheAge(p.refreshMark) >= 45 {
			if os.WriteFile(p.refreshMark, []byte(dotNetRoundTripStamp(time.Now())), 0o644) == nil {
				spawnDetachedRefresh()
			}
		}
	}

	raw, _ := io.ReadAll(os.Stdin)
	var j payload
	_ = json.Unmarshal(stripBOM(raw), &j)

	model := j.Model.DisplayName
	modelID := j.Model.ID
	cwd := j.Workspace.CurrentDir
	if cwd == "" {
		cwd = j.Cwd
	}
	dir := shortDir(cwd)
	tpath := j.TranscriptPath
	style := j.OutputStyle.Name

	branch, gitMarks := gitStatus(cwd)

	is1m := oneMillion.MatchString(modelID)
	limit := 200000
	if is1m {
		limit = 1000000
	}
	shortModel := strip1MSuffix.ReplaceAllString(model, "")
	for _, r := range modelShorten {
		shortModel = r.re.ReplaceAllString(shortModel, r.with)
	}
	modelLabel := shortModel
	if is1m {
		modelLabel = shortModel + " 1M"
	}

	tx := scanTranscript(p, tpath, j.SessionID)

	pct := roundToEven(float64(tx.tokens)/float64(limit)*100, 1)
	if limit <= 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}

	// Progress bar (5 cells)
	const barLen = 5
	filled := int(math.Floor(pct / 100 * barLen))
	if filled > barLen {
		filled = barLen
	}
	if filled < 0 {
		filled = 0
	}
	bar := strings.Repeat("█", filled) + strings.Repeat("░", barLen-filled)
	tokStr := fmtTok(tx.tokens) + "/" + fmtTok(limit)

	// Color the bar by pressure.
	// 1M model: yellow at 200K (premium pricing tier), red at 800K (capacity).
	// 200K model: yellow at 70%, red at 90%.
	var barColor string
	if is1m {
		switch {
		case tx.tokens >= 800000:
			barColor = red
		case tx.tokens >= 600000:
			barColor = maroon
		case tx.tokens >= 400000:
			barColor = orange
		case tx.tokens >= 200000:
			barColor = yellow
		default:
			barColor = green
		}
	} else {
		switch {
		case pct >= 90:
			barColor = red
		case pct >= 70:
			barColor = yellow
		default:
			barColor = green
		}
	}

	wparts := weatherParts(p.weatherCache)

	// A disabled verse line is simply absent. Nulling it HERE flows through everything
	// downstream for free: weatherOnVerse below, the divider (drawn only when BOTH
	// exist), and the weather's fallback onto row 1 when no reference line is rendered.
	var verseBG, verseYV *verse
	if cfg.VerseBibleGateway {
		verseBG = readVerseCache(p.verseBGCache)
	}
	if cfg.VerseYouVersion {
		verseYV = readVerseCache(p.verseYVCache)
	}
	weatherOnVerse := verseYV != nil || verseBG != nil

	row1 := []string{cyan + modelLabel + reset}
	if dir != "" {
		row1 = append(row1, bold+dir+reset)
	}
	if !weatherOnVerse {
		row1 = append(row1, wparts...)
	}

	row2 := []string{}
	if branch != "" {
		branchStr := branch
		if gitMarks != "" {
			branchStr = branch + " " + gitMarks
		}
		row2 = append(row2, yellow+branchStr+reset)
	}
	row2 = append(row2, barColor+bar+" "+fmtFloatPS(pct)+"%"+reset)
	row2 = append(row2, barColor+tokStr+reset)

	isAnthropic := anthropicName.MatchString(model) || anthropicID.MatchString(modelID)

	var row3 []string

	// Last main-chain API call, as local time. This one value anchors BOTH the "@ time"
	// stamp and the prompt-cache countdown, so the two can never disagree. Prefer the
	// timestamp parsed out of the transcript (the true moment of the API call); fall
	// back to the transcript's mtime only when that is unavailable.
	//
	// Why not mtime outright: a long subagent run keeps bumping mtime while the MAIN
	// conversation's cache quietly ages out, so mtime would report "fresh" at exactly
	// the moment the cache the countdown is about was expiring.
	var lastActivity time.Time
	if tx.lastMainTs != "" {
		if t, ok := parseDotNetTime(tx.lastMainTs); ok {
			lastActivity = t
		}
	}
	if lastActivity.IsZero() {
		if st, err := os.Stat(tpath); tpath != "" && err == nil {
			lastActivity = st.ModTime()
		} else {
			lastActivity = time.Now()
		}
	}

	durPart := ""
	workMs := j.Cost.TotalAPIDurationMs
	if workMs == nil {
		workMs = j.Cost.TotalDurationMs
	}
	if workMs != nil {
		secs := psInt(*workMs / 1000)
		h := secs / 3600
		m := (secs % 3600) / 60
		s := secs % 60
		var dur string
		switch {
		case h > 0:
			dur = strconv.Itoa(h) + "h " + d2(m) + "m"
		case m > 0:
			dur = strconv.Itoa(m) + "m " + d2(s) + "s"
		default:
			dur = strconv.Itoa(s) + "s"
		}
		// "@ time" = when the last main-chain API call happened, so it FREEZES while the
		// session sits idle -- a refreshInterval tick re-runs us, but this stays pinned to
		// the last real activity rather than tracking the wall clock. Elapsed stays dim;
		// the stamp is ALWAYS bold lime-green.
		durPart = dim + dur + reset + " " + pop + "@ " + lastActivity.Format("3:04 PM") + reset
	}

	cachePart := ""
	if isAnthropic {
		cachePart = renderCacheChip(cfg, tx, lastActivity)
	}

	if isAnthropic && j.Cost.TotalCostUSD != nil && *j.Cost.TotalCostUSD > 0 {
		costVal := *j.Cost.TotalCostUSD
		t := computeCost(cfg, p, j.SessionID, tpath, costVal)

		// Per-window color, escalating thresholds (green -> yellow -> red).
		cS := costColor(costVal, 1, 5)
		cH := costColor(t.fiveHour, 5, 20)
		c7 := costColor(t.sevenDay, 25, 75)
		c30 := costColor(t.thirtyDay, 150, 300)
		// s$0.00/h$2.33/7d$23.33/30d$200.02 -- labels + slashes dim, amounts colored.
		// With cost_windows off the three window figures are all 0.00 and would read as
		// real zeros, so emit the session figure alone rather than a row of empty windows.
		if cfg.CostWindows {
			row3 = append(row3, dim+"s"+reset+cS+"$"+fmtN2(costVal)+reset+
				dim+"/h"+reset+cH+"$"+fmtN2(t.fiveHour)+reset+
				dim+"/7d"+reset+c7+"$"+fmtN2(t.sevenDay)+reset+
				dim+"/30d"+reset+c30+"$"+fmtN2(t.thirtyDay)+reset)
		} else {
			row3 = append(row3, cS+"$"+fmtN2(costVal)+reset)
		}
	}

	// Subscription usage (5h + 7d + scoped caps) via the undocumented OAuth endpoint --
	// read from cache ONLY here; the background -refresh-only pass refetches it.
	var partsBottom []string
	if isAnthropic {
		partsBottom = append(partsBottom, renderQuota(cfg, p, id)...)
	}

	if style != "" && style != "default" {
		row3 = append(row3, dim+style+reset)
	}

	row2Line := joinParts(append(row2, row3...))

	// One counter chip: prompts you sent -> API calls they turned into. The arrow
	// carries the relationship two separate chips left implicit, and the gap between
	// the numbers IS the signal -- it is the subagent + tool-loop work each turn
	// spawned. Dim: reference, not something to act on.
	if tx.promptCount > 0 || tx.llmCount > 0 {
		partsBottom = append(partsBottom, dim+"#"+strconv.Itoa(tx.promptCount)+"→"+
			strconv.Itoa(tx.llmCount)+" calls"+reset)
	}
	// Duration trails the TOP row, with the prompt-cache countdown last so the urgent
	// chip sits at the end of the row.
	if durPart != "" {
		row1 = append(row1, durPart)
	}
	if cachePart != "" {
		row1 = append(row1, cachePart)
	}

	if len(row1) > 0 {
		emit(w, joinParts(row1))
	}
	if row2Line != "" {
		emit(w, row2Line)
	}
	if len(partsBottom) > 0 {
		emit(w, joinParts(partsBottom))
	}

	// Second line -- context warning only (the harness already shows bypass mode).
	if pct >= 90 {
		emit(w, red+"! context "+fmtFloatPS(pct)+"%"+reset)
	}

	// Verse of the Day output. The verses themselves were read above (before row 1) so
	// row 1 could tell whether a reference line would exist to carry the weather chips.
	termWidth := terminalWidth()
	wrapAt := termWidth / 2
	if wrapAt < 60 {
		wrapAt = 60
	}
	rnd := rand.New(rand.NewSource(time.Now().UnixNano()))

	// Weather rides the FIRST reference line rendered -- YouVersion when present, else
	// Bible Gateway. Only one of them carries it; whichever verse comes second gets a
	// bare ref.
	wSuffix := ""
	if weatherOnVerse && len(wparts) > 0 {
		wSuffix = pipe + strings.Join(wparts, pipe)
	}
	if verseYV != nil {
		for _, l := range formatVerse(verseYV, wrapAt, rnd, wSuffix) {
			emit(w, l)
		}
		wSuffix = ""
	}
	if verseBG != nil && verseYV != nil {
		emit(w, dim+strings.Repeat("─", wrapAt)+reset)
	}
	if verseBG != nil {
		for _, l := range formatVerse(verseBG, wrapAt, rnd, wSuffix) {
			emit(w, l)
		}
	}
}

// renderCacheChip is the prompt-cache countdown -- the money chip. Per session
// (anchored to THIS session's transcript), so other terminals can never move it.
// Four states, escalating:
//
//	green  >15m left   fine
//	yellow <=15m left  heads up, wrap up or plan to re-arm
//	RED    <=6m  left  blinking: act now (send anything to refresh the cache)
//	TOMB   expired     solid block, counts UP: too late, resuming pays a full re-cache
//
// Renders as ONE chip carrying both cache signals: "cache 55m/+1.5K". The minutes say
// how long the cache still LIVES; the "+N" says how much NEW (non-cached) data the
// last turn had to pay premium for. They are independent, so each keeps its own color
// and only the "/" is dim.
func renderCacheChip(cfg Config, tx txResult, lastActivity time.Time) string {
	ttlPart := ""
	// Effective TTL: trust the API's own report over the configured default. Under
	// usage overage Anthropic silently drops the cache to a 5-minute TTL -- assuming 60
	// there would leave the countdown wildly optimistic at exactly the moment cost
	// matters most. Thresholds scale with it, so a 5-min TTL warns proportionally
	// instead of never warning (a fixed 15-min warn band cannot fire inside a 5-min
	// life). CONFIRMED IN THE WILD 2026-08-11 on an account that had just hit 100% of
	// its 5-hour budget: 384 consecutive writes reported ephemeral_1h, then every write
	// two minutes later reported ephemeral_5m. Silent, mid-session; this tag is the
	// only warning.
	effTtl := cfg.CacheTTLMin
	if cfg.CacheTTLMin <= 0 {
		effTtl = 0
	} else if tx.lastTtlKind == "5m" {
		effTtl = 5
	}
	ttlScale := 1.0
	if cfg.CacheTTLMin > 0 {
		ttlScale = float64(effTtl) / float64(cfg.CacheTTLMin)
	}
	ttlTag := ""
	if effTtl > 0 && effTtl != cfg.CacheTTLMin {
		ttlTag = "(" + strconv.Itoa(effTtl) + "m)"
	}
	if !lastActivity.IsZero() && effTtl > 0 {
		minsLeft := float64(effTtl) - time.Since(lastActivity).Minutes()
		if minsLeft > 0 {
			// "cache" stays tinted WITH the countdown (not dimmed) so the crit state blinks
			// as a whole word -- dimming the label would soften the one alarm that has to
			// be unmissable.
			var cColor string
			switch {
			case minsLeft <= float64(cfg.CacheCritMin)*ttlScale:
				cColor = alarm
			case minsLeft <= float64(cfg.CacheWarnMin)*ttlScale:
				cColor = yellow
			default:
				cColor = green
			}
			ttlPart = cColor + "cache" + ttlTag + " " + strconv.Itoa(int(math.Ceil(minsLeft))) + "m" + reset
		} else {
			// Count UP since expiry: "just lost it" and "gone for hours, do not bother" are
			// different decisions, and only the elapsed number tells them apart.
			goneM := int(math.Floor(-minsLeft))
			goneStr := strconv.Itoa(goneM) + "m"
			if goneM >= 60 {
				goneStr = strconv.Itoa(goneM/60) + "h " + d2(goneM%60) + "m"
			}
			ttlPart = tomb + " cache" + ttlTag + " DEAD " + goneStr + " " + reset
		}
	}

	// NEW tokens on the last main-chain turn (uncached input + cache writes) -- the data
	// actually paid premium for. Green under 10K covers the ordinary turn (measured p90
	// is ~6.9K); yellow/red mark the genuine outliers, where a big cache write at 2x base
	// input is real money (a 162K-token write on Opus is roughly $5).
	newPart := ""
	if tx.haveNew {
		nColor := green
		if tx.newTokens >= 50000 {
			nColor = red
		} else if tx.newTokens >= 10000 {
			nColor = yellow
		}
		newPart = nColor + "+" + fmtTok(tx.newTokens) + reset
	}

	// Either half can be absent. A lone "+N" still needs the "cache" label the countdown
	// would have supplied, so it gets a dim one.
	switch {
	case ttlPart != "" && newPart != "":
		return ttlPart + dim + "/" + reset + newPart
	case ttlPart != "":
		return ttlPart
	case newPart != "":
		return dim + "cache " + reset + newPart
	}
	return ""
}

func renderQuota(cfg Config, p paths, id *identity) []string {
	u, ok := readUsageCache(p.usageCache)
	if !ok {
		return nil
	}
	var parts []string

	// Identity guard: is this cache actually THIS profile's? The tag below is still
	// rendered either way -- it comes from the profile folder and stays correct; it is
	// the NUMBERS that would be another account's.
	identityOk := true
	peNow := id.profileEmail()
	if peNow != "" && u.Email != "" && u.Email != peNow {
		identityOk = false
	}

	// ---- STALENESS GUARD ----
	// Unlike the identity guard (another ACCOUNT's numbers -> render nothing), a stale
	// cache still holds THIS account's last known numbers, so they are worth showing --
	// but they must not read as live. Diagnosed 2026-08-22: one failed refetch at session
	// start left row 3 printing 8-hour-old percentages at full-strength colors, with both
	// reset arrows pointing at times already PAST, and nothing said so. Two signals,
	// either is enough:
	//   a) a top-level resets_at already in the past -- proof the window has ROLLED.
	//      weekly_scoped is excluded on purpose: its resets_at is null until the scope is
	//      used (an idle Fable reads 0%).
	//   b) the file older than 2x its max age -- one render cycle behind is the normal
	//      stale-while-revalidate case; twenty means the refetch is failing.
	usageAge := cacheAge(p.usageCache)
	usageStale := usageAge > 2*usageMaxAge
	for _, ra := range []string{u.FiveHour.ResetsAt, u.SevenDay.ResetsAt} {
		if t, ok := parseDotNetTime(ra); ok && t.Before(time.Now()) {
			usageStale = true
		}
	}

	if u.Email != "" {
		// Profile-folder match wins (it distinguishes accounts sharing a domain); else
		// email-domain suffix; else the email's username.
		profLeaf := ".claude"
		if v := os.Getenv("CLAUDE_CONFIG_DIR"); v != "" {
			profLeaf = filepath.Base(strings.TrimRight(v, `\/`))
		}
		tag := cfg.ProfileTags[profLeaf]
		if tag == "" {
			for _, dom := range cfg.accountTagDomains() {
				if strings.HasSuffix(u.Email, dom) {
					tag = cfg.AccountTags[dom]
					break
				}
			}
		}
		if tag == "" {
			tag = strings.SplitN(u.Email, "@", 2)[0]
		}
		parts = append(parts, magenta+tag+reset)
	}
	if !identityOk {
		// Render NOTHING rather than another account's numbers under this tag. A refetch
		// has already been marked due (backoff permitting), so this clears within a render
		// cycle or two.
		parts = append(parts, dim+"quota stale"+reset)
	}
	// One age chip for the whole group, not one per number. Hours past ~90 min so a
	// genuinely dead refetch reads as "hours", never as an ambiguous 3-digit minute.
	if identityOk && usageStale {
		staleLbl := fmtDec(usageAge/60, 0) + "m"
		if usageAge >= 5400 {
			staleLbl = fmtDec(usageAge/3600, 0) + "h"
		}
		parts = append(parts, dim+"stale "+staleLbl+reset)
	}
	if identityOk && u.FiveHour.Utilization != nil {
		bp := psInt(*u.FiveHour.Utilization)
		seg := quotaColor(bp, usageStale) + "5h " + strconv.Itoa(bp) + "%" + reset
		if t, ok := parseDotNetTime(u.FiveHour.ResetsAt); ok {
			seg += dim + " ↻ " + t.Format("3:04 PM") + reset
		}
		parts = append(parts, seg)
	}
	if identityOk && u.SevenDay.Utilization != nil {
		wp := psInt(*u.SevenDay.Utilization)
		wseg := quotaColor(wp, usageStale) + "7d " + strconv.Itoa(wp) + "%" + reset
		if t, ok := parseDotNetTime(u.SevenDay.ResetsAt); ok {
			days := int(math.Ceil(time.Until(t).Hours() / 24))
			if days < 1 {
				days = 1
			}
			wseg += dim + " ↻ " + t.Format("Mon 3:04 PM") + " (" + strconv.Itoa(days) + "d)" + reset
		}
		parts = append(parts, wseg)
	}
	// Model-scoped weekly limits (e.g. Fable) live ONLY in the limits[] array -- there is
	// NO top-level utilization key for them like five_hour/seven_day. One lean chip per
	// scoped model after 7d: 2-letter label (Fable -> Fa) + %, same colors.
	if identityOk {
		for _, lim := range u.Limits {
			if lim.Kind != "weekly_scoped" || lim.Scope == nil || lim.Scope.Model == nil ||
				lim.Scope.Model.DisplayName == "" || lim.Percent == nil {
				continue
			}
			mp := psInt(*lim.Percent)
			dn := lim.Scope.Model.DisplayName
			mlabel := dn
			if r := []rune(dn); len(r) >= 2 {
				mlabel = string(r[:2])
			}
			parts = append(parts, quotaColor(mp, usageStale)+mlabel+" "+strconv.Itoa(mp)+"%"+reset)
		}
	}
	return parts
}

func quotaColor(pct int, stale bool) string {
	switch {
	case stale:
		return dim
	case pct >= 80:
		return red
	case pct >= 50:
		return yellow
	}
	return green
}

func costColor(v, warn, crit float64) string {
	switch {
	case v >= crit:
		return red
	case v >= warn:
		return yellow
	}
	return green
}

// shortDir is "<parent>/<leaf>" of the working directory, or just the leaf at a
// filesystem root -- Split-Path -Leaf over Split-Path -Parent.
func shortDir(cwd string) string {
	if cwd == "" {
		return ""
	}
	clean := strings.TrimRight(cwd, `\/`)
	if clean == "" || strings.HasSuffix(clean, ":") {
		return filepath.Base(cwd)
	}
	leaf := filepath.Base(clean)
	parentPath := filepath.Dir(clean)
	if parentPath == clean {
		return leaf
	}
	parent := filepath.Base(strings.TrimRight(parentPath, `\/`))
	if parent == "" || parent == "." || parent == string(filepath.Separator) || strings.HasSuffix(parent, ":") {
		return leaf
	}
	return parent + "/" + leaf
}

// fmtFloatPS is PowerShell's default double-to-string: the shortest representation
// that round-trips, with no trailing ".0" (16.8 -> "16.8", 17.0 -> "17").
func fmtFloatPS(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }
