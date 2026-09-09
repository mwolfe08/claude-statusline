package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Token usage -- the last assistant message's usage in the transcript, plus the two
// session counters.
//
// INCREMENTAL, not a full re-read. The transcript is append-only and this box writes
// ~0.9 MB/hour of it, so re-reading the whole thing on a 60s timer made this the one
// cost in the script that got WORSE the longer a session ran -- and therefore worst
// in exactly the long sessions where the statusline is watched most. Everything this
// block produces is either a RUNNING TOTAL (the two counters) or a LAST-WINS value
// (the token bar, the cache anchor, the TTL kind), and both kinds survive being
// carried forward -- so persist them beside a byte OFFSET and parse only the bytes
// appended since the previous render.
//
// REJECTED: scanning BACKWARD to find just the last usage line. It only optimizes the
// cheap half -- the counters genuinely need every line, so a full forward read would
// still have been paid on every render.
type txResult struct {
	tokens      int
	newTokens   int
	haveNew     bool
	promptCount int
	llmCount    int
	lastMainTs  string
	lastTtlKind string
}

var (
	nonAlnum      = regexp.MustCompile(`[^A-Za-z0-9]`)
	sidechainTrue = regexp.MustCompile(`"isSidechain"\s*:\s*true`)
	ephemeral1h   = regexp.MustCompile(`"ephemeral_1h_input_tokens":\s*[1-9]`)
	ephemeral5m   = regexp.MustCompile(`"ephemeral_5m_input_tokens":\s*[1-9]`)
)

type usageLine struct {
	Timestamp string `json:"timestamp"`
	Message   struct {
		Usage struct {
			InputTokens         *int `json:"input_tokens"`
			CacheReadInputToks  int  `json:"cache_read_input_tokens"`
			CacheCreateInputTok int  `json:"cache_creation_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

func scanTranscript(p paths, tpath, sessionID string) txResult {
	var r txResult
	if tpath == "" {
		return r
	}
	if _, err := os.Stat(tpath); err != nil {
		return r
	}

	// Per-session state file, keyed by session_id (1:1 with the transcript path), so
	// two concurrent sessions can never share one. Contrast the cost tracker's
	// windows.cache, which IS read by every session and therefore needs the atomic
	// tmp+move dance: a single writer means a plain write is enough here. A torn file
	// fails the field-count check below and costs exactly one full rescan.
	txKey := nonAlnum.ReplaceAllString(sessionID, "")
	if txKey == "" {
		txKey = nonAlnum.ReplaceAllString(tpath, "")
	}
	if txKey == "" {
		txKey = "default"
	}
	txState := filepath.Join(p.txDir, "tx-"+txKey+".state")

	// Carried state: v1 <offset> <prompts> <llm> <inp> <cread> <ccrt> <ttlKind> <ts>,
	// with '-' for an absent value. Nine whitespace-free fields on one line.
	var (
		scanFrom  int64
		haveCarry bool
		cInp, cCread, cCcrt int
		cTs       string
	)
	if raw, err := os.ReadFile(txState); err == nil {
		f := strings.Fields(strings.TrimSpace(string(raw)))
		if len(f) == 9 && f[0] == "v1" {
			scanFrom, _ = strconv.ParseInt(f[1], 10, 64)
			r.promptCount, _ = strconv.Atoi(f[2])
			r.llmCount, _ = strconv.Atoi(f[3])
			if f[4] != "-" {
				cInp, _ = strconv.Atoi(f[4])
				cCread, _ = strconv.Atoi(f[5])
				cCcrt, _ = strconv.Atoi(f[6])
				haveCarry = true
			}
			if f[7] != "-" {
				r.lastTtlKind = f[7]
			}
			if f[8] != "-" {
				cTs = f[8]
			}
		}
	}

	var (
		lastUsage string
		newOffset int64
		newLines  []string
	)
	// Go opens with FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE, which is what
	// this needs: the harness holds the transcript open for append while we read it.
	if fh, err := os.Open(tpath); err == nil {
		func() {
			defer fh.Close()
			st, err := fh.Stat()
			if err != nil {
				return
			}
			flen := st.Size()
			// Two ways a stored offset can be a lie: the file was truncated or rotated
			// (now shorter than the offset), or it was rewritten in place. The first is
			// caught by the length test; the second by requiring the byte just before
			// the offset to still be the newline that ended the last line consumed.
			// Either way the answer is the same -- drop the carried totals and rescan
			// whole, because a wrong baseline would silently poison every later render.
			if scanFrom > flen {
				scanFrom = 0
			}
			if scanFrom > 0 {
				var b [1]byte
				if _, err := fh.ReadAt(b[:], scanFrom-1); err != nil || b[0] != '\n' {
					scanFrom = 0
				}
			}
			if scanFrom == 0 {
				r.promptCount, r.llmCount, r.lastTtlKind, haveCarry = 0, 0, "", false
			}
			newOffset = scanFrom
			want := flen - scanFrom
			if want <= 0 {
				return
			}
			buf := make([]byte, want)
			got, _ := io.ReadFull(io.NewSectionReader(fh, scanFrom, want), buf)
			// Stop at the LAST newline. Anything after it is a record the harness is
			// still writing: consuming it would parse a half-written line AND advance
			// the offset past a line about to be completed, losing it for good. Cutting
			// on a newline is also what makes reading from a byte offset safe at all --
			// UTF-8 never places 0x0A inside a multi-byte sequence, so the boundary
			// cannot fall mid-character.
			cut := -1
			for k := got - 1; k >= 0; k-- {
				if buf[k] == '\n' {
					cut = k
					break
				}
			}
			if cut >= 0 {
				newOffset = scanFrom + int64(cut) + 1
				newLines = strings.Split(string(buf[:cut+1]), "\n")
			}
		}()
	}

	for _, line := range newLines {
		// TRAP: a Task (subagent) COMPLETION record is written on the MAIN chain as a
		// type:user tool_result with isSidechain:FALSE, and it republishes the
		// subagent's entire usage block -- input_tokens, cache_read, and the
		// ephemeral_5m/1h split. It therefore sails straight past the isSidechain gate
		// below and poisons every consumer here: the token bar snaps to the subagent's
		// context, lastTtlKind flips to '5m', and the cache clock re-anchors to the
		// subagent's finish time -- so a perfectly healthy 1h main cache renders "cache
		// DEAD" about 5 minutes after ANY subagent returns, mid-session, while work is
		// running. Only an assistant message's own usage counts: toolUseResult is a
		// user-side field, so no genuine assistant line carries it.
		if strings.Contains(line, `"input_tokens"`) && !strings.Contains(line, `"toolUseResult"`) {
			r.llmCount++
			// MAIN-CHAIN ONLY for the token bar + the cache clock. A subagent runs its
			// own prompt with its own prefix, so its usage is not THIS conversation's
			// context and its API call does not refresh this conversation's cached
			// prefix. llmCount still counts EVERY call: that chip means total work done.
			if !sidechainTrue.MatchString(line) {
				lastUsage = line
				// Which cache TTL the API actually used, straight from the data rather
				// than assumed. Most turns are pure cache READS with both buckets at
				// zero and say nothing, so remember the most recent turn that actually
				// WROTE cache.
				if ephemeral1h.MatchString(line) {
					r.lastTtlKind = "1h"
				} else if ephemeral5m.MatchString(line) {
					r.lastTtlKind = "5m"
				}
			}
		}
		// Real user turn: type=user, no tool_use_id (excludes tool results), not isMeta
		// (excludes <local-command-caveat> injections), and not the slash-command
		// wrapper or its captured stdout.
		if strings.Contains(line, `"type":"user"`) &&
			!strings.Contains(line, `"tool_use_id"`) &&
			!strings.Contains(line, `"isMeta":true`) &&
			!strings.Contains(line, `<command-name>`) &&
			!strings.Contains(line, `<local-command-stdout>`) {
			r.promptCount++
		}
		// Interrupt: user typed a message while a tool was running. Stored as
		// type=attachment with a queued_command payload.
		if strings.Contains(line, `"queued_command"`) {
			r.promptCount++
		}
	}

	// A render usually appends no main-chain usage line at all (the timer fires between
	// turns), so the last-wins values come from the carried state instead. Parity with
	// the old full scan is exact: when a new line IS present it wins outright.
	var inp, cread, ccrt int
	haveUsage := false
	if lastUsage == "" && haveCarry {
		inp, cread, ccrt = cInp, cCread, cCcrt
		haveUsage = true
		r.lastMainTs = cTs
	}
	if lastUsage != "" {
		var o usageLine
		if json.Unmarshal([]byte(lastUsage), &o) == nil {
			// Cache anchor: wall-clock of the last main-chain API call -- the call that
			// (re)wrote this conversation's prompt cache. Read off the PARSED object
			// rather than regexing the raw line, because nested content can carry its
			// own "timestamp" keys that a regex would match first.
			if o.Timestamp != "" {
				r.lastMainTs = o.Timestamp
			}
			if u := o.Message.Usage; u.InputTokens != nil {
				inp, cread, ccrt = *u.InputTokens, u.CacheReadInputToks, u.CacheCreateInputTok
				haveUsage = true
			}
		}
	}
	if haveUsage {
		r.tokens = inp + cread + ccrt
		if r.tokens > 0 {
			// NEW data on this turn = everything NOT served from cache. That is what
			// moves the bill: a cache WRITE bills at 2x base input on the 1h TTL versus
			// 0.1x for a read. HISTORY: this used to be cread/tokens ("what fraction was
			// cached"), pinned near 100% in any warm session -- over 864 real main-chain
			// turns, 24% rendered exactly "100%". Correct and useless. Do not restore it.
			r.newTokens = inp + ccrt
			r.haveNew = true
		}
	}

	// Publish the state this render ends on, for the next one to resume from. newOffset
	// stays 0 when the transcript holds no complete line yet (or the read failed), and
	// nothing is written in that case -- better to rescan a 1-line file next time than
	// to record an offset the scan never actually reached.
	if newOffset > 0 {
		_ = os.MkdirAll(p.txDir, 0o755)
		fUse := "- - -"
		if haveUsage {
			fUse = strconv.Itoa(inp) + " " + strconv.Itoa(cread) + " " + strconv.Itoa(ccrt)
		}
		fTtl, fTs := r.lastTtlKind, r.lastMainTs
		if fTtl == "" {
			fTtl = "-"
		}
		if fTs == "" {
			fTs = "-"
		}
		_ = os.WriteFile(txState, []byte(strings.Join([]string{
			"v1", strconv.FormatInt(newOffset, 10),
			strconv.Itoa(r.promptCount), strconv.Itoa(r.llmCount),
			fUse, fTtl, fTs,
		}, " ")), 0o644)

		// One state file per session, so prune on the FULL-RESCAN path -- which every
		// new session hits on its first render, and no hot path ever hits. Letting these
		// accumulate would repeat the cost tracker's per-PID forerunner (~1700 files,
		// slow enough that Claude Code cancelled the script and the line went blank).
		if scanFrom == 0 {
			cutoff := time.Now().AddDate(0, 0, -3)
			if entries, err := os.ReadDir(p.txDir); err == nil {
				for _, e := range entries {
					name := e.Name()
					if !strings.HasPrefix(name, "tx-") || !strings.HasSuffix(name, ".state") {
						continue
					}
					if info, err := e.Info(); err == nil && info.ModTime().Before(cutoff) {
						_ = os.Remove(filepath.Join(p.txDir, name))
					}
				}
			}
		}
	}
	return r
}
