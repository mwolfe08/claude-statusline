package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Four-window cost: s = THIS SESSION's cost / h = 5h / 7d / 30d spend across all
// sessions, pooled over every account (the canonical cost-tracker dir).
//
// total_cost_usd is the harness's PER-SESSION cost. Keep one time series per session
// -- "<epoch> <cumulative>" in ~/.claude\cost-tracker\sess-<id>.series -- and compute
// each window as the sum of POSITIVE deltas across every session's series (one curve
// per session => summing IS the real cross-session total). A frozen reconstruction
// file seed.series carries older history.
//
// (History: ~2026-06-24 a Claude Code bug briefly made total_cost_usd report a SHARED,
// per-account cumulative growing into the thousands; the old statusline summed that one
// shared curve once per PID-keyed file and ballooned 30d to ~$1,000,000. Keying by
// session_id -- directly available, no ~600 ms process-tree walk -- is both correct for
// the normal per-session value and far cheaper.)
const costCacheTTLSec = 60

var seriesLine = regexp.MustCompile(`^(\d+)\s+([0-9.]+)`)

type costTotals struct {
	fiveHour  float64
	sevenDay  float64
	thirtyDay float64
}

// fmtRoundTrip is '{0:R}'. Go's shortest-round-trip 'f' formatting is used rather
// than 'g' on purpose: it never emits exponential notation, and the series parser
// (seriesLine, and the PowerShell version's identical regex) accepts only digits and
// dots. A value small enough to make .NET print "1E-07" would be silently dropped by
// BOTH readers; printing it plainly is the strictly safer of the two.
func fmtRoundTrip(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }

func computeCost(cfg Config, p paths, sessionID, tpath string, costVal float64) costTotals {
	var t costTotals
	if !cfg.CostWindows {
		return t
	}
	serKey := nonAlnumUnderscore(sessionID)
	if serKey == "" {
		serKey = nonAlnumUnderscore(tpath)
	}
	if serKey == "" {
		serKey = "default"
	}
	if os.MkdirAll(p.costDir, 0o755) != nil {
		return t
	}

	now := time.Now()
	nowEpoch := now.Unix()
	pruneEpoch := nowEpoch - 32*86400 // > widest displayed window (30d) + margin

	myseries := filepath.Join(p.costDir, "sess-"+serKey+".series")
	winCache := filepath.Join(p.costDir, "windows.cache")

	// Append this session's cumulative to its series, throttled to ~1 sample / 10 min,
	// pruning samples older than 32 days. Most renders only read the last line; the
	// file is rewritten only when adding a sample.
	var (
		lastEpoch int64
		myLastCm  float64
		myHasCm   bool
	)
	existing, haveSeries := readLines(myseries)
	if haveSeries && len(existing) > 0 {
		// This session's last cumulative ALREADY ON DISK. Needed because the shared
		// aggregate below covers only on-disk samples, so this session's spend since its
		// last write has to be added back separately.
		if m := seriesLine.FindStringSubmatch(existing[len(existing)-1]); m != nil {
			lastEpoch, _ = strconv.ParseInt(m[1], 10, 64)
			myLastCm, _ = strconv.ParseFloat(m[2], 64)
			myHasCm = true
		}
	}
	if nowEpoch-lastEpoch >= 600 {
		keep := make([]string, 0, len(existing)+1)
		for _, ln := range existing {
			if m := seriesLine.FindStringSubmatch(ln); m != nil {
				if ep, err := strconv.ParseInt(m[1], 10, 64); err == nil && ep >= pruneEpoch {
					keep = append(keep, ln)
				}
			}
		}
		keep = append(keep, strconv.FormatInt(nowEpoch, 10)+" "+fmtRoundTrip(costVal))
		// Set-Content writes CRLF and a trailing newline; match it so the two
		// implementations can hand these files back and forth mid-migration.
		_ = os.WriteFile(myseries, []byte(strings.Join(keep, "\r\n")+"\r\n"), 0o644)
		// A new on-disk sample just landed, so any shared aggregate computed before now
		// is short by exactly that delta. Drop it rather than serve a stale sum.
		_ = os.Remove(winCache)
		myLastCm = costVal // what we just wrote IS the current value
		myHasCm = true
	}

	// Window starts. Each boundary recurs on a fixed grid; snap to the most recent one
	// at/before now so even a stale resets_at anchor yields the CURRENT window instead
	// of reaching back a whole extra block.
	winStart5h := now.Add(-5 * time.Hour)
	winStart7d := now.AddDate(0, 0, -7)
	if u, ok := readUsageCache(p.usageCache); ok {
		if ra, ok := parseDotNetTime(u.FiveHour.ResetsAt); ok {
			blocks := mathFloor(now.Sub(ra).Hours() / 5.0)
			winStart5h = ra.Add(time.Duration(5*blocks) * time.Hour)
		}
		if ra, ok := parseDotNetTime(u.SevenDay.ResetsAt); ok {
			blocks := mathFloor(now.Sub(ra).Hours() / 24.0 / 7.0)
			winStart7d = ra.AddDate(0, 0, 7*blocks)
		}
	}

	// 30d billing window: most recent anchorDay at 00:00 local, clamped to the month
	// length so short months never overflow.
	anchorDay := cfg.BillingAnchorDay
	if anchorDay < 1 {
		anchorDay = 1
	}
	if anchorDay > 31 {
		anchorDay = 31
	}
	aNow := minInt(anchorDay, daysInMonth(now.Year(), now.Month()))
	var winStart30d time.Time
	if now.Day() >= aNow {
		winStart30d = time.Date(now.Year(), now.Month(), aNow, 0, 0, 0, 0, now.Location())
	} else {
		prev := now.AddDate(0, -1, 0)
		aPrev := minInt(anchorDay, daysInMonth(prev.Year(), prev.Month()))
		winStart30d = time.Date(prev.Year(), prev.Month(), aPrev, 0, 0, 0, 0, prev.Location())
	}
	e5h, e7d, e30d := winStart5h.Unix(), winStart7d.Unix(), winStart30d.Unix()

	// SHARED AGGREGATE. Every open session was independently summing the SAME ~610 files
	// to the SAME answer once a minute -- N sessions paying N times over for one result.
	// The on-disk portion is session-independent, so compute it once and publish it; the
	// only session-specific part is this session's live delta, added after the loop.
	//
	// Reused ONLY when all three window boundaries match. They snap to a fixed grid and
	// hold for hours, but the no-resets_at fallback slides continuously, and a sum taken
	// against a different boundary is simply the wrong number -- so that degraded case
	// misses every time and recomputes: correct-but-slow, never fast-but-wrong.
	var sum5h, sum7d, sum30d float64
	cacheHit := false
	if raw, err := os.ReadFile(winCache); err == nil {
		wc := strings.Fields(strings.TrimSpace(string(raw)))
		if len(wc) == 7 {
			stamp, e1 := strconv.ParseInt(wc[0], 10, 64)
			w5, e2 := strconv.ParseInt(wc[1], 10, 64)
			w7, e3 := strconv.ParseInt(wc[2], 10, 64)
			w30, e4 := strconv.ParseInt(wc[3], 10, 64)
			if e1 == nil && e2 == nil && e3 == nil && e4 == nil &&
				stamp <= nowEpoch && stamp >= nowEpoch-costCacheTTLSec &&
				w5 == e5h && w7 == e7d && w30 == e30d {
				a, ea := strconv.ParseFloat(wc[4], 64)
				b, eb := strconv.ParseFloat(wc[5], 64)
				c, ec := strconv.ParseFloat(wc[6], 64)
				if ea == nil && eb == nil && ec == nil {
					sum5h, sum7d, sum30d, cacheHit = a, b, c, true
				}
			}
		}
	}

	myBase := "sess-" + serKey
	if !cacheHit {
		// On a cache HIT the scan is skipped entirely; pruning rides along with the
		// recompute (~1/min) exactly as it did before.
		//
		// os.ReadDir returns names sorted, where .NET's Directory.GetFiles returned NTFS
		// directory order. Only the ORDER of float additions differs, and the result is
		// printed to two decimals, so the two cannot disagree in the rendered output.
		entries, _ := os.ReadDir(p.costDir)
		for _, e := range entries {
			name := e.Name()
			if e.IsDir() || !strings.HasSuffix(name, ".series") {
				continue
			}
			sfPath := filepath.Join(p.costDir, name)
			sfBase := strings.TrimSuffix(name, ".series")

			// STREAMING single pass. The previous shape built two ArrayLists per file and
			// walked copies; across ~600 files that allocation churn was the 2nd-costliest
			// thing in the script. Deltas accumulate into locals and are committed to the
			// running totals only AFTER the prune test -- which is all the two-pass shape
			// was actually buying.
			var (
				n              int
				lastEp         int64
				prevCm         float64
				a5, a7, a30    float64
			)
			lines, ok := readLines(sfPath)
			if !ok {
				continue
			}
			for _, ln := range lines {
				m := seriesLine.FindStringSubmatch(ln)
				if m == nil {
					continue
				}
				ep, err1 := strconv.ParseInt(m[1], 10, 64)
				cm, err2 := strconv.ParseFloat(m[2], 64)
				if err1 != nil || err2 != nil {
					continue
				}
				if n > 0 {
					// Per-window spend = sum of POSITIVE deltas between consecutive samples
					// whose later sample falls in the window. Clamping each delta at 0
					// tolerates a cumulative DROP (a billing/account reset, or a legacy
					// recycled-PID file) by treating the lower run as a fresh baseline
					// instead of letting it undercount.
					if d := cm - prevCm; d > 0 {
						if ep > e5h {
							a5 += d
						}
						if ep > e7d {
							a7 += d
						}
						if ep > e30d {
							a30 += d
						}
					}
				}
				n++
				prevCm = cm
				lastEp = ep
			}
			if n == 0 {
				continue
			}
			// Keep the directory bounded by pruning files that can no longer affect any
			// window -- they otherwise pile up one-per-session (the per-PID forerunner
			// reached ~1700 files, slow enough to blank the line):
			//   - newest sample past the widest (30d) window, or
			//   - a lone sample from a finished session (baseline == latest => $0).
			// Skip the current session's own file; give a just-started session 1200s
			// (2x the 600s throttle) before its single-sample file is treated as done.
			if sfBase != myBase && (lastEp < pruneEpoch || (n <= 1 && lastEp < nowEpoch-1200)) {
				_ = os.Remove(sfPath)
				continue
			}
			// Commit only now: a pruned file must contribute nothing, which is the one
			// thing the old collect-then-walk ordering was really enforcing.
			sum5h += a5
			sum7d += a7
			sum30d += a30
		}

		// Publish the on-disk aggregate for every other session to read. Temp file plus
		// atomic overwrite-move, so a concurrent reader sees either the whole old value or
		// the whole new one and never a half-written line. Two sessions racing to
		// recompute derive the same answer, so losing that race costs nothing.
		tmpWc := winCache + "." + strconv.Itoa(os.Getpid()) + ".tmp"
		payload := strings.Join([]string{
			strconv.FormatInt(nowEpoch, 10),
			strconv.FormatInt(e5h, 10),
			strconv.FormatInt(e7d, 10),
			strconv.FormatInt(e30d, 10),
			fmtRoundTrip(sum5h), fmtRoundTrip(sum7d), fmtRoundTrip(sum30d),
		}, " ")
		if os.WriteFile(tmpWc, []byte(payload), 0o644) == nil {
			if os.Rename(tmpWc, winCache) != nil {
				_ = os.Remove(tmpWc) // never orphan the temp
			}
		} else {
			_ = os.Remove(tmpWc)
		}
		// Sweep any temps stranded by an earlier failure (only on the ~1/min recompute
		// path, so this costs nothing on the hot path).
		if entries, err := os.ReadDir(p.costDir); err == nil {
			for _, e := range entries {
				n := e.Name()
				if strings.HasPrefix(n, "windows.cache.") && strings.HasSuffix(n, ".tmp") {
					_ = os.Remove(filepath.Join(p.costDir, n))
				}
			}
		}
	}

	// This session's own live delta -- the part that is NOT shareable: spend since its
	// last on-disk sample. Guarded by myHasCm so a missing or unparseable series file
	// contributes nothing, rather than counting the whole cumulative as fresh spend.
	if myHasCm {
		if dLive := costVal - myLastCm; dLive > 0 {
			if nowEpoch > e5h {
				sum5h += dLive
			}
			if nowEpoch > e7d {
				sum7d += dLive
			}
			if nowEpoch > e30d {
				sum30d += dLive
			}
		}
	}
	t.fiveHour, t.sevenDay, t.thirtyDay = sum5h, sum7d, sum30d
	return t
}

func readLines(p string) ([]string, bool) {
	raw, err := os.ReadFile(p)
	if err != nil {
		return nil, false
	}
	s := strings.ReplaceAll(string(raw), "\r\n", "\n")
	s = strings.TrimSuffix(s, "\n")
	if s == "" {
		return nil, true
	}
	return strings.Split(s, "\n"), true
}

func nonAlnumUnderscore(s string) string {
	if s == "" {
		return ""
	}
	// nonAlnum is compiled once at package scope. Compiling it here instead would pay a
	// regex compile on the hot path of every render, for a pattern that never changes.
	return nonAlnum.ReplaceAllString(s, "_")
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func daysInMonth(y int, m time.Month) int {
	return time.Date(y, m+1, 0, 0, 0, 0, 0, time.Local).Day()
}

func mathFloor(v float64) int {
	i := int(v)
	if v < 0 && float64(i) != v {
		i--
	}
	return i
}
