# PV Calculator

A Python script for calculating theoretical PV DC production under clear sky conditions. This tool uses the `pvlib` library to estimate solar panel output based on location, system specifications, and time.

## Features

- Calculate theoretical DC power output for solar PV systems
- Support for instant, specific time, and timeframe calculations
- Multiple output formats (table, JSON, Prometheus metrics)
- Timezone-aware calculations using system or specified timezone
- Configurable time resolution for timeframe calculations
- Optional `config.cfg` file for storing default system parameters

## Requirements

```bash
pip install -r requirements.txt
```

## Configuration

System parameters can be stored in `config.cfg` so you don't need to pass them on every invocation. Command-line arguments always override config file values.

```ini
[system]
latitude = 41.000
longitude = 22.000
system_capacity = 10.0
panel_tilt = 30.0
panel_azimuth = 180.0
timezone = Europe/Athens
shortname = mysystem
```

A custom config file path can be specified with `--config /path/to/config.cfg`.

## Usage

### Basic Usage

```bash
./pvcalc.py --now
```

If `config.cfg` is present, the system parameters are loaded from it. Without a config file, all system parameters must be supplied on the command line:

```bash
./pvcalc.py --latitude <lat> --longitude <lon> --system-capacity <kW> --panel-tilt <degrees> --panel-azimuth <degrees> [options]
```

### Time Options

- Current time:
```bash
--now
# or
--time=now
```

- Specific time:
```bash
--time "2024-03-20 12:00"
```

- Time range:
```bash
--timeframe "2024-03-20:2024-03-21"
```

### Optional Parameters

- `--config`: Path to config file (default: `config.cfg` next to the script)
- `--timezone`: Timezone name (default: value from config, or system timezone)
- `--shortname`: Short identifier for the system (default: value from config)
- `--resolution`: Time resolution for timeframe calculations (1min, 10min, 20min, 30min, 1H)
- `--format`: Output format (table, json, prometheus)

### Examples

1. Get current production using values from `config.cfg`:
```bash
./pvcalc.py --now
```

2. Override a single parameter from the config:
```bash
./pvcalc.py --now --system-capacity 12.0
```

3. Get current production in table format (no config file):
```bash
./pvcalc.py --latitude 41.000 --longitude 22.000 --system-capacity 10.0 --panel-tilt 30.0 --panel-azimuth 180.0 --now
```

4. Get production for specific time in JSON format:
```bash
./pvcalc.py --time "2024-03-20 12:00" --format json
```

5. Get production in Prometheus format with a custom config file:
```bash
./pvcalc.py --now --format prometheus --config /etc/pvcalc/site2.cfg
```

6. Get production over a timeframe:
```bash
./pvcalc.py --timeframe "2024-03-20:2024-03-21" --resolution 30min
```

## Output Formats

### Table Format (default)
```
Time                DC Power    POA Irr    GHI
------------------  ----------  ---------  --------
2024-03-20 12:00   5.23 kW     850 W/m²   750 W/m²
```

### JSON Format
```json
{
  "timestamp": "2024-03-20 12:00 EET",
  "dc_power_kw": 5.23,
  "poa_irradiance": 850.0,
  "ghi": 750.0
}
```

### Prometheus Format
```
theoretical_pv_watts{shortname="mysystem",plant="theoretical",capacity="10.0"} 5230.00
```

## Notes

- Panel azimuth angle: 180° represents South, 90° East, 270° West
- Timeframe calculations filter out negligible production values (< 0.001 kW)
- All calculations assume clear sky conditions
- Time values are timezone-aware

## License

This project is open-sourced under the MIT license.
