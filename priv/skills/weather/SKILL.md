---
description: Fetch weather information from Open-Meteo API
always: false
requires:
  bins: []
  env: []
---

# Weather Skill

Use this skill to fetch current and forecast weather data from Open-Meteo (https://open-meteo.com), a free open-source weather API.

## Overview

Open-Meteo provides free weather data without requiring an API key. You can fetch:
- Current weather conditions
- Hourly forecasts (up to 48 hours)
- Daily forecasts (up to 16 days)
- Historical weather data

## API Endpoints

### Current Weather

**URL:** `https://api.open-meteo.com/v1/forecast`

**Parameters:**
- `latitude` (required): Latitude coordinate (e.g., 40.71 for New York)
- `longitude` (required): Longitude coordinate (e.g., -74.01 for New York)
- `current_weather` (optional): Set to `true` to include current conditions
- `temperature_unit` (optional): `celsius` (default) or `fahrenheit`
- `windspeed_unit` (optional): `kmh` (default), `mph`, or `ms`
- `timezone` (optional): IANA timezone (e.g., `America/New_York`)

### Hourly/Daily Forecast

**Additional Parameters:**
- `hourly` (optional): Comma-separated variables: `temperature_2m,relativehumidity_2m,precipitation`
- `daily` (optional): Comma-separated variables: `temperature_2m_max,temperature_2m_min,precipitation_sum`

## Available Weather Variables

### Current Weather Variables
- `temperature`: Current temperature
- `windspeed`: Wind speed
- `winddirection`: Wind direction (degrees)
- `weathercode`: WMO weather code
- `time`: Timestamp

### Hourly/Daily Variables
- `temperature_2m`: Temperature at 2 meters
- `relativehumidity_2m`: Relative humidity
- `dewpoint_2m`: Dew point temperature
- `apparent_temperature`: Feels-like temperature
- `precipitation`: Precipitation (mm)
- `rain`: Rain amount
- `snowfall`: Snowfall amount
- `cloudcover`: Cloud cover percentage
- `windspeed_10m`: Wind speed at 10 meters
- `winddirection_10m`: Wind direction
- `shortwave_radiation`: Solar radiation
- `uv_index`: UV index

## Weather Codes (WMO)

| Code | Description |
|------|-------------|
| 0 | Clear sky |
| 1, 2, 3 | Mainly clear, partly cloudy, overcast |
| 45, 48 | Fog |
| 51, 53, 55 | Drizzle (light, moderate, dense) |
| 56, 57 | Freezing drizzle |
| 61, 63, 65 | Rain (slight, moderate, heavy) |
| 66, 67 | Freezing rain |
| 71, 73, 75 | Snow (slight, moderate, heavy) |
| 77 | Snow grains |
| 80, 81, 82 | Rain showers |
| 85, 86 | Snow showers |
| 95 | Thunderstorm |
| 96, 99 | Thunderstorm with hail |

## Example Requests

### Get current weather for a city

```bash
# New York City (40.71, -74.01)
curl "https://api.open-meteo.com/v1/forecast?latitude=40.71&longitude=-74.01&current_weather=true&temperature_unit=fahrenheit"
```

### Get 7-day forecast with daily temperatures

```bash
curl "https://api.open-meteo.com/v1/forecast?latitude=40.71&longitude=-74.01&daily=temperature_2m_max,temperature_2m_min,precipitation_sum&timezone=America/New_York"
```

### Get hourly forecast for next 24 hours

```bash
curl "https://api.open-meteo.com/v1/forecast?latitude=40.71&longitude=-74.01&hourly=temperature_2m,precipitation&forecast_days=1"
```

## Common City Coordinates

| City | Latitude | Longitude |
|------|----------|-----------|
| New York | 40.71 | -74.01 |
| Los Angeles | 34.05 | -118.24 |
| London | 51.51 | -0.13 |
| Paris | 48.86 | 2.35 |
| Tokyo | 35.68 | 139.69 |
| Sydney | -33.87 | 151.21 |
| Beijing | 39.90 | 116.41 |
| Dubai | 25.20 | 55.27 |
| Singapore | 1.35 | 103.82 |

## Using with fetch_url Tool

When using the `fetch_url` tool, format the URL with proper encoding:

```
fetch_url("https://api.open-meteo.com/v1/forecast?latitude=40.71&longitude=-74.01&current_weather=true&temperature_unit=fahrenheit")
```

## Response Format

The API returns JSON with the following structure:

```json
{
  "latitude": 40.71,
  "longitude": -74.01,
  "current_weather": {
    "temperature": 72.5,
    "windspeed": 10.2,
    "winddirection": 180,
    "weathercode": 0,
    "time": "2026-03-06T15:00"
  },
  "daily": {
    "time": ["2026-03-06", "2026-03-07"],
    "temperature_2m_max": [75.0, 72.0],
    "temperature_2m_min": [55.0, 52.0]
  }
}
```

## Best Practices

1. **Always specify timezone**: This ensures times are in the correct local time
2. **Use temperature_unit=fahrenheit for US users**: Default is Celsius
3. **Combine parameters**: Request multiple variables in a single call to minimize API usage
4. **Handle missing data**: Not all variables are available for all locations
5. **Cache coordinates**: Look up city coordinates once and reuse them

## Geocoding

To convert city names to coordinates, use the Geocoding API:

```
https://geocoding-api.open-meteo.com/v1/search?name=New York&count=1
```

This returns matching locations with their coordinates.

## Error Handling

The API may return errors for:
- Invalid coordinates (400)
- Server errors (500)

Always check the response structure before parsing.