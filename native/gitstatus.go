package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Git status -- branch + dirty/ahead/behind markers.
//
// ONE git spawn, not two. `status --porcelain=v1 -b` ALREADY reports the branch on
// its `## ...` header line, so the `rev-parse --abbrev-ref HEAD` that used to gate it
// was pure duplicate work. That matters more than it looks: a git.exe spawn costs
// 30-160 ms on this box (bimodal -- Defender rescans the image whenever it falls out
// of its cache), and this runs on EVERY render in EVERY open session. Measured
// 2026-08-06 it was the single most expensive avoidable thing in the script.
// Do NOT reintroduce rev-parse "for clarity" -- the branch is already in hand.
//
// This is the one process the native build still spawns. Everything the ahead/behind
// and dirty marks need is a full index-vs-worktree comparison; reimplementing that is
// a git client, not a status line.
var (
	detachedHead = regexp.MustCompile(`^## HEAD \(no branch\)`)
	branchHead   = regexp.MustCompile(`^## (?:No commits yet on )?(.+?)(?:\.\.\.|\s\[|$)`)
	aheadBy      = regexp.MustCompile(`ahead (\d+)`)
	behindBy     = regexp.MustCompile(`behind (\d+)`)
)

func gitStatus(cwd string) (branch, marks string) {
	if cwd == "" {
		return "", ""
	}
	if st, err := os.Stat(cwd); err != nil || !st.IsDir() {
		return "", ""
	}
	// Do not spawn git for a directory that is not in a work tree at all. `git status`
	// there prints nothing and the row renders no branch, so the spawn buys exactly
	// nothing -- and this is not a rare case: the workspace root this runs in most often
	// (dev/personal) is deliberately not a repo, so EVERY render was paying a process
	// start to be told so. Walking up for a .git entry is an in-process stat per level.
	//
	// .git is a directory in a normal clone and a FILE in a worktree or submodule, so
	// both count. GIT_DIR set in the environment overrides the search entirely, and is
	// rare enough to just spawn for.
	if os.Getenv("GIT_DIR") == "" && !inWorkTree(cwd) {
		return "", ""
	}
	cmd := exec.Command("git", "status", "--porcelain=v1", "-b")
	cmd.Dir = cwd
	cmd.Stderr = nil
	out, err := cmd.Output()
	if err != nil && len(out) == 0 {
		return "", ""
	}
	text := strings.TrimRight(string(out), "\r\n")
	if text == "" {
		return "", ""
	}
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	headLine := lines[0]

	// `## <branch>` shapes: "main", "main...origin/main", "main...origin/main [ahead 1]",
	// "No commits yet on main", and detached "HEAD (no branch)" -- which rev-parse
	// --abbrev-ref rendered as a bare "HEAD", so keep that spelling for continuity.
	if detachedHead.MatchString(headLine) {
		branch = "HEAD"
	} else if m := branchHead.FindStringSubmatch(headLine); m != nil {
		branch = m[1]
	}
	if branch == "" {
		return "", ""
	}

	ahead, behind := 0, 0
	if m := aheadBy.FindStringSubmatch(headLine); m != nil {
		ahead, _ = strconv.Atoi(m[1])
	}
	if m := behindBy.FindStringSubmatch(headLine); m != nil {
		behind, _ = strconv.Atoi(m[1])
	}
	dirty := len(lines) - 1

	if dirty > 0 {
		marks += "*"
	}
	if ahead > 0 {
		marks += "+" + strconv.Itoa(ahead)
	}
	if behind > 0 {
		marks += "-" + strconv.Itoa(behind)
	}
	return branch, marks
}

// inWorkTree reports whether dir, or any ancestor, holds a .git entry.
func inWorkTree(dir string) bool {
	for {
		if _, err := os.Lstat(filepath.Join(dir, ".git")); err == nil {
			return true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return false
		}
		dir = parent
	}
}
