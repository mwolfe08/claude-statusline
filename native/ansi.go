package main

import (
	"math"
	"strconv"
	"strings"
)

// ANSI palette. Identical escape sequences to statusline.ps1 lines 603-620 -- these
// are compared byte-for-byte against the PowerShell output, so do not "tidy" a code
// into an equivalent shorter form.
const (
	esc = "\x1b"

	cyan    = esc + "[36m"
	bold    = esc + "[1m"
	yellow  = esc + "[33m"
	green   = esc + "[32m"
	red     = esc + "[31m"
	dim     = esc + "[2m"
	magenta = esc + "[35m"
	reset   = esc + "[0m"
	orange  = esc + "[38;5;208m"
	maroon  = esc + "[38;5;88m"
	blue    = esc + "[34m"

	// pop = the "run finished" highlight for the trailing duration chip: bold +
	// vivid green so WHEN the last run finished jumps out.
	pop = esc + "[1m" + esc + "[38;5;46m"
	// alarm = "act now" -- bold + BLINK + the most saturated red. Used by the
	// prompt-cache chip in its last few minutes, while re-arming is still possible.
	alarm = esc + "[1m" + esc + "[5m" + esc + "[38;5;196m"
	// tomb = "the prompt cache is already gone". Deliberately NOT blinking: blink
	// means "act now", and once the cache has lapsed there is nothing left to save.
	tomb = esc + "[1m" + esc + "[38;5;231m" + esc + "[48;5;52m"

	pipe = " " + dim + "|" + reset + " "
)

// ---------------------------------------------------------------------------
// .NET / PowerShell numeric parity
//
// The three rounding modes in the original are NOT interchangeable and the output
// is compared byte-for-byte, so each one is reproduced explicitly:
//
//	[math]::Round(x, d)   -> MidpointRounding.ToEven   (banker's)
//	[int]$double          -> Convert.ToInt32           (banker's)
//	'{0:N2}' / '{0:0.#}'  -> .NET Framework formatting (half away from zero)
//
// Go's strconv rounds half-to-even, so the format paths are done on the decimal
// string rather than with FormatFloat's precision argument. Taking the shortest
// round-trip representation first is what reproduces .NET Framework's 15-digit
// intermediate: the classic 2.675 case ("2.68" in .NET, "2.67" from a naive
// FormatFloat(v,'f',2,64)) comes out right this way.
// ---------------------------------------------------------------------------

// roundToEven is [math]::Round(value, digits) -- banker's rounding.
func roundToEven(v float64, digits int) float64 {
	p := math.Pow(10, float64(digits))
	return math.RoundToEven(v*p) / p
}

// psInt is PowerShell's [int] cast on a double, which is Convert.ToInt32 and
// therefore rounds half to EVEN, not away from zero: [int]2.5 is 2, [int]3.5 is 4.
func psInt(v float64) int {
	return int(math.RoundToEven(v))
}

// fmtDec renders v with exactly `places` decimals, rounding half away from zero,
// the way .NET Framework's numeric format strings do.
func fmtDec(v float64, places int) string {
	neg := math.Signbit(v) && v != 0
	if neg {
		v = -v
	}
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return strconv.FormatFloat(v, 'f', places, 64)
	}
	s := strconv.FormatFloat(v, 'f', -1, 64) // shortest round-trip, never exponential
	intPart, frac, _ := strings.Cut(s, ".")

	if len(frac) <= places {
		frac += strings.Repeat("0", places-len(frac))
	} else {
		roundUp := frac[places] >= '5'
		frac = frac[:places]
		if roundUp {
			digits := []byte(intPart + frac)
			i := len(digits) - 1
			for ; i >= 0; i-- {
				if digits[i] < '9' {
					digits[i]++
					break
				}
				digits[i] = '0'
			}
			if i < 0 {
				digits = append([]byte{'1'}, digits...)
			}
			cut := len(digits) - places
			intPart, frac = string(digits[:cut]), string(digits[cut:])
		}
	}
	out := intPart
	if places > 0 {
		out += "." + frac
	}
	if neg && strings.Trim(out, "0.,") != "" {
		out = "-" + out
	}
	return out
}

// fmtN2 is '{0:N2}': two decimals with comma group separators, e.g. 24360.5 ->
// "24,360.50". The grouping matters -- the cost chip prints four of these.
func fmtN2(v float64) string {
	s := fmtDec(v, 2)
	sign := ""
	if strings.HasPrefix(s, "-") {
		sign, s = "-", s[1:]
	}
	intPart, frac, _ := strings.Cut(s, ".")
	var b strings.Builder
	for i, ch := range intPart {
		if i > 0 && (len(intPart)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(ch)
	}
	return sign + b.String() + "." + frac
}

// fmtOptional1 is '{0:0.#}': up to one decimal place, trailing ".0" dropped.
func fmtOptional1(v float64) string {
	s := fmtDec(v, 1)
	if strings.HasSuffix(s, ".0") {
		return s[:len(s)-2]
	}
	return s
}

// fmtTok mirrors Fmt-Tok (statusline.ps1:595): 1.2M / 168.5K / 42.
func fmtTok(n int) string {
	switch {
	case n >= 1000000:
		return fmtOptional1(float64(n)/1000000.0) + "M"
	case n >= 1000:
		return fmtOptional1(float64(n)/1000.0) + "K"
	default:
		return strconv.Itoa(n)
	}
}

// d2 is '{0:D2}' -- zero-padded to two digits.
func d2(n int) string {
	if n < 10 && n >= 0 {
		return "0" + strconv.Itoa(n)
	}
	return strconv.Itoa(n)
}

// joinParts renders one status row: the parts separated by the dim pipe.
func joinParts(parts []string) string {
	return strings.Join(parts, pipe)
}
