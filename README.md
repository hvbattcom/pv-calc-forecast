# pv-calc-forecast

A single CLI tool for solar PV **clear-sky calculation** and **weather-based forecasting**, powered by [pvlib](https://pvlib-python.readthedocs.io) and multiple forecast sources.

Supports **multiple PV strings** (panel arrays with different orientations) in a single run — designed to be used as a long-running Prometheus exporter service. Timezone is **auto-detected from coordinates** — no need to specify it manually.

## Features

- **Calculate mode** — theoretical DC output under clear-sky conditions via pvlib
- **Forecast mode** — real weather forecast from three sources, with local pvlib transposition to your actual tilt/azimuth
- **Multi-string support** — define multiple panel arrays (PV1, PV2, PV3…) via config or CLI; per-string and total metrics emitted
- Forecast caching (1 hour TTL) — weather data fetched once per location, transposed per string
- Output formats: human-readable table, JSON, Prometheus metrics
- `config.cfg` for storing system parameters

## Requirements

```bash
pip install -r requirements.txt
```

## Configuration

### Multi-string (recommended)

Define each panel array as a named section in `config.cfg`. Section names become the `string=` label in Prometheus output.

```ini
[system]
latitude  = 41.000
longitude = 22.000
timezone  = Europe/Athens

[PV1]
capacity = 15     # kWp
tilt     = 30     # degrees from horizontal
azimuth  = 205    # degrees clockwise from North (180=South, 90=East, 270=West)

[PV2]
capacity = 10
tilt     = 25
azimuth  = 90

[PV3]
capacity = 5
tilt     = 25
azimuth  = 270
```

### Single-string (legacy / one-off runs)

```ini
[system]
latitude        = 41.000
longitude       = 22.000
system_capacity = 10.0
panel_tilt      = 30.0
panel_azimuth   = 180.0
shortname       = mysystem
```

A custom config path can be specified with `--config /path/to/config.cfg`.

## Usage

```
pv-calc-forecast.py (--calculate | --forecast) [options]
```

### Multi-string via CLI

Strings can be defined directly on the command line with repeatable `--string` flags (overrides config sections):

```bash
./pv-calc-forecast.py --forecast=open-meteo --format=prometheus \
  --latitude=41.000 --longitude=22.000 --timezone=Europe/Athens \
  --string PV1:15:30:205 \
  --string PV2:10:25:90 \
  --string PV3:5:25:270
```

Format: `NAME:CAPACITY_kWp:TILT_deg:AZIMUTH_deg`

### Calculate mode

Uses pvlib to compute theoretical DC output under clear-sky conditions.

```bash
# Current moment
./pv-calc-forecast.py --calculate --now

# Specific time
./pv-calc-forecast.py --calculate --time "2024-06-15 12:00"

# Date range (hourly by default)
./pv-calc-forecast.py --calculate --timeframe "2024-06-15:2024-06-16"

# Date range at 30-minute resolution
./pv-calc-forecast.py --calculate --timeframe "2024-06-15:2024-06-16" --resolution 30min
```

**Calculate-only options:**

| Option | Description |
|--------|-------------|
| `--now` | Use current time |
| `--time YYYY-MM-DD HH:MM` | Specific timestamp |
| `--timeframe YYYY-MM-DD:YYYY-MM-DD` | Date range |
| `--resolution` | `1min`, `10min`, `20min`, `30min`, `1H` (default: `1H`) |

### Forecast mode

Fetches a weather-based solar forecast. Three sources are available:

| Source | Flag | Horizon | Rate limit | Auth | Transposition |
|--------|------|---------|------------|------|---------------|
| forecast.solar | `--forecast` or `--forecast=forecast-solar` | ~2 days | 12 req/h (free) | none | ratio method via clear-sky |
| Open-Meteo | `--forecast=open-meteo` | 7 days | none | none | exact (real DNI/DHI) |
| Solcast | `--forecast=solcast` | 7 days | 10 calls/day (free) | API key | pre-computed by Solcast |

forecast.solar and Open-Meteo transpose the forecast to your actual panel tilt/azimuth using pvlib. Solcast uses the tilt/azimuth and capacity you registered in your [Solcast account](https://solcast.com) — no local transposition is performed.

All sources cache results locally. Cache TTL: 1 hour for forecast.solar and Open-Meteo, 4 hours for Solcast.

```bash
# forecast.solar (default)
./pv-calc-forecast.py --forecast

# Open-Meteo (7-day horizon, no rate limit, exact transposition)
./pv-calc-forecast.py --forecast=open-meteo

# Solcast (requires a registered rooftop site and API key)
./pv-calc-forecast.py --forecast=solcast --solcast-api-key=YOUR_KEY

# Also include next-hour power
./pv-calc-forecast.py --forecast=open-meteo --show-current-hour
```

**Forecast-only options:**

| Option | Description |
|--------|-------------|
| `--show-current-hour` | Also emit next-hour power forecast metric |
| `--hourly-window START-END` | Minutes within each hour to emit full hourly data in Prometheus format (default: `0-5`) |
| `--show-days N` | Number of days to include in forecast output (default: 3) |
| `--solcast-api-key KEY` | Solcast API key (or `solcast_api_key` in config.cfg) |
| `--solcast-resource-id ID` | Solcast rooftop site resource ID (auto-detected if only one site is registered) |

### Shared options

| Option | Description |
|--------|-------------|
| `--latitude` | Location latitude |
| `--longitude` | Location longitude |
| `--timezone` | Override timezone (auto-detected from coordinates if omitted) |
| `--string NAME:CAPACITY:TILT:AZIMUTH` | Define a PV string (repeatable; overrides config sections) |
| `--system-capacity` | System capacity in kWp (single-string mode only) |
| `--panel-tilt` | Panel tilt in degrees (single-string mode only) |
| `--panel-azimuth` | Panel azimuth in degrees (single-string mode only) |
| `--shortname` | String name to use in single-string mode |
| `--format` | `human` (default), `json`, `prometheus` |
| `--config` | Path to config file |

## Output formats

### Human (default)

Calculate mode — single point:
```
--------------  ---------------------
Time            2024-06-15 12:00 EEST
DC Power        8.59 kW
POA Irradiance  858.82 W/m²
GHI             849.22 W/m²
--------------  ---------------------
```

Forecast mode — multi-string:
```
=== PV1 ===
Date          Energy (Wh)
----------  -------------
2024-06-15        110,618

=== PV2 ===
Date          Energy (Wh)
----------  -------------
2024-06-15         67,693
```

### JSON

Multi-string forecast:
```json
{
  "PV1": {
    "watt_hours_day": { "2024-06-15": 110618 },
    "watts_tilted":   { "2024-06-15 08:00:00": 1462 }
  },
  "PV2": {
    "watt_hours_day": { "2024-06-15": 67693 },
    "watts_tilted":   { "2024-06-15 08:00:00": 890 }
  }
}
```

### Prometheus

All metrics use a `string=` label. When multiple strings are configured, a `string="total"` row is also emitted.

Calculate mode:
```
theoretical_pv_watts{string="PV1",plant="theoretical",capacity="15.0"} 8250.00
theoretical_pv_watts{string="PV2",plant="theoretical",capacity="10.0"} 4100.00
theoretical_pv_watts{string="total",plant="theoretical",capacity="25.0"} 12350.00
```

Forecast mode:
```
# HELP solar_forecast_watt_hours_day Forecasted solar energy production in watt-hours per day
# TYPE solar_forecast_watt_hours_day gauge
solar_forecast_watt_hours_day{string="PV1",forecast="solar",date="2024-06-15"} 110618
solar_forecast_watt_hours_day{string="PV2",forecast="solar",date="2024-06-15"} 67693
solar_forecast_watt_hours_day{string="total",forecast="solar",date="2024-06-15"} 178311

# HELP solar_forecast_hour_watts Forecasted solar power output per hour in watts, labelled by date and hour
# TYPE solar_forecast_hour_watts gauge
solar_forecast_hour_watts{string="PV1",date="2024-06-15",hour="14:00"} 18500
solar_forecast_hour_watts{string="PV2",date="2024-06-15",hour="14:00"} 9200
solar_forecast_hour_watts{string="total",date="2024-06-15",hour="14:00"} 27700

# HELP solar_forecast_current_hour_watts Forecasted solar power output for the current hour in watts
# TYPE solar_forecast_current_hour_watts gauge
solar_forecast_current_hour_watts{string="PV1",forecast="hourly"} 18500
solar_forecast_current_hour_watts{string="PV2",forecast="hourly"} 9200
solar_forecast_current_hour_watts{string="total",forecast="hourly"} 27700
```

## Notes

- Timezone is auto-detected from latitude/longitude using `timezonefinder`; set `timezone` in `[system]` to avoid the ~4s startup cost on ARM boards
- Panel azimuth: 180° = South, 90° = East, 270° = West
- `--string` flags take priority over `[PV*]` config sections, which take priority over single-string CLI params
- Weather data is fetched once per location and transposed independently per string — no extra API calls for additional strings
- Calculate mode filters out negligible production values (< 0.001 kW) and assumes clear-sky conditions
- Forecast mode daily totals are summed from the transposed hourly values, not taken from the raw API response
- Open-Meteo uses actual DNI/DHI from its NWP model for an exact pvlib transposition; forecast.solar uses a clear-sky ratio approximation (the API only exposes total watts, not irradiance components)
- Solcast rooftop forecasts use the tilt, azimuth and capacity configured in your Solcast account dashboard; for multi-string Solcast use, add `solcast_resource_id` to each `[PV*]` section
- Solcast free tier: 10 API calls/day — results are cached for 4 hours; expired cache is used on rate-limit errors
- `--hourly-window` only gates the hourly block in Prometheus format; human and JSON output always include the full hourly table

## Solcast setup

1. Create a free account at [solcast.com](https://solcast.com)
2. Register your rooftop site with its actual tilt, azimuth and capacity
3. Copy your API key from the account dashboard
4. Add to `config.cfg`:
   ```ini
   solcast_api_key = your-key-here
   # Per-string resource IDs in each [PV*] section:
   # [PV1]
   # solcast_resource_id = b1e1-c590-b64e-dc50
   ```

## License

MIT
