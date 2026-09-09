package main

import (
	"encoding/json"
	"math"
	"os"
	"strconv"
	"time"
)

// Weather -- Open-Meteo, location from the weather_lat/weather_lon config knobs.
// Served from cache ONLY; the background -refresh-only pass refetches it (12-hour
// max age). Blank coords simply yield no cached weather.
//
// The chips do NOT render on row 1: they ride the verse REFERENCE line at the very
// bottom. Row 1 is reserved for session state (model, dir, duration, cache
// countdown), and weather is ambient, so it belongs with the other ambient text.
// With no verse cached there is no reference line to hang it on, and it falls back
// onto row 1 rather than vanishing.
type weatherCacheDoc struct {
	Weather struct {
		Current struct {
			Temperature2m   float64 `json:"temperature_2m"`
			WeatherCode     float64 `json:"weather_code"`
			WindSpeed10m    float64 `json:"wind_speed_10m"`
			WindDirection10 float64 `json:"wind_direction_10m"`
		} `json:"current"`
		Daily struct {
			Time                     []string  `json:"time"`
			WindSpeed10mMax          []float64 `json:"wind_speed_10m_max"`
			PrecipitationProbability []float64 `json:"precipitation_probability_max"`
		} `json:"daily"`
	} `json:"weather"`
}

var compassDirs = [8]string{"N", "NE", "E", "SE", "S", "SW", "W", "NW"}

// weatherParts returns the weather chip followed by up to two forecast alerts, in
// the order they are rendered. An empty slice means "no weather to show".
func weatherParts(cacheFile string) []string {
	raw, err := os.ReadFile(cacheFile)
	if err != nil {
		return nil
	}
	var doc weatherCacheDoc
	if json.Unmarshal(stripBOM(raw), &doc) != nil {
		return nil
	}
	w := doc.Weather
	if len(w.Daily.Time) == 0 && w.Current.Temperature2m == 0 && w.Current.WeatherCode == 0 {
		// Nothing parsed -- an empty or foreign document. Same outcome as a missing file.
		return nil
	}

	temp := psInt(math.RoundToEven(w.Current.Temperature2m))
	wcode := int(w.Current.WeatherCode)
	wmph := psInt(math.RoundToEven(w.Current.WindSpeed10m))

	// Every glyph is written as an escape, never as a literal. The PowerShell file is
	// UTF-8 with NO BOM and 5.1 decodes a BOM-less script using the ANSI codepage, so a
	// literal middle dot once arrived as its two UTF-8 bytes decoded separately and the
	// fallback branch rendered a stray capital-A-circumflex. Go has no such hazard, but
	// the OUTPUT still has to match byte-for-byte, so the code points are spelled out.
	var glyph string
	switch {
	case wcode == 0:
		glyph = "☀"
	case wcode == 1 || wcode == 2 || wcode == 3:
		glyph = "⛅"
	case wcode == 45 || wcode == 48:
		glyph = "\U0001F32B"
	case wcode >= 51 && wcode <= 67:
		glyph = "\U0001F327"
	case wcode >= 71 && wcode <= 77:
		glyph = "❄"
	case wcode >= 80 && wcode <= 82:
		glyph = "\U0001F327"
	case wcode >= 95 && wcode <= 99:
		glyph = "⛈"
	default:
		glyph = "·"
	}

	compass := compassDirs[((psInt(math.RoundToEven(w.Current.WindDirection10/45.0))%8)+8)%8]

	var wColor string
	switch {
	case wcode <= 1:
		wColor = yellow
	case wcode >= 71 && wcode <= 77:
		wColor = cyan
	case wcode >= 51 && wcode <= 82:
		wColor = blue
	case wcode >= 95:
		wColor = magenta
	default:
		wColor = dim
	}

	parts := []string{
		wColor + glyph + " " + strconv.Itoa(temp) + "F " + compass + "/" + strconv.Itoa(wmph) + "mph" + reset,
	}

	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	var rainAlert, windAlert string
	for i := 1; i < len(w.Daily.Time); i++ {
		dt, ok := parseForecastDay(w.Daily.Time[i])
		if !ok {
			continue
		}
		daysOut := int(dt.Sub(today).Hours() / 24)
		dayName := dt.Format("Mon")

		if rainAlert == "" && i < len(w.Daily.PrecipitationProbability) {
			if prob := int(w.Daily.PrecipitationProbability[i]); prob >= 50 {
				rainAlert = blue + "rain " + dayName + "+" + strconv.Itoa(daysOut) + "d " +
					strconv.Itoa(prob) + "%" + reset
			}
		}
		if windAlert == "" && i < len(w.Daily.WindSpeed10mMax) {
			if maxMph := psInt(math.RoundToEven(w.Daily.WindSpeed10mMax[i])); maxMph >= 20 {
				windAlert = yellow + "wind " + dayName + "+" + strconv.Itoa(daysOut) + "d " +
					strconv.Itoa(maxMph) + "mph" + reset
			}
		}
		if rainAlert != "" && windAlert != "" {
			break
		}
	}
	if rainAlert != "" {
		parts = append(parts, rainAlert)
	}
	if windAlert != "" {
		parts = append(parts, windAlert)
	}
	return parts
}

func parseForecastDay(s string) (time.Time, bool) {
	for _, layout := range []string{"2006-01-02", time.RFC3339, "2006-01-02T15:04"} {
		if t, err := time.ParseInLocation(layout, s, time.Local); err == nil {
			return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.Local), true
		}
	}
	return time.Time{}, false
}
