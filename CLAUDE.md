# Smart Birdfeeder Project

## Project Overview
A solar-powered smart birdfeeder built on a Raspberry Pi Zero 2 W with an RPi Camera Module 3 Wide. The system detects birds via a PIR motion sensor, captures photos, and uploads them to Firebase. A Flutter desktop app provides a dashboard for viewing sightings, live camera feed, energy stats, and system configuration.

## Architecture

### Hardware
- Raspberry Pi Zero 2 W (main compute)
- RPi Camera Module 3 Wide
- PIR motion sensor (GPIO pin 4)
- ADS1115 ADC module (I2C, address 0x48) for voltage monitoring
- Two solar panels + battery (single-cell LiPo, 3.2V-4.2V range)
- Voltage divider ratios: Solar (A0) = 2.419, Battery (A1) = 1.435

### Pi-Side Code (`Birdfeeder/PythonScripts/`)
The system runs through `master_control.py` which manages child processes via Firestore listeners:

**Active scripts (launched by master_control.py):**
- `master_control.py` — Main orchestrator. Listens to Firestore for state changes, manages lifecycle of child scripts, sends heartbeat with IP address every 30s. Runs as the always-on entry point.
- `camera_server.py` — TCP JPEG streaming server (port 8000). Hardware-encoded lores stream for live feed + high-res main stream for snapshots. Launched when `status/streaming_enabled.enabled = true`.
- `system_updater.py` — Combined config listener + periodic data uploader. Listens to `config/settings` in Firestore, normalizes and saves settings locally. Also runs `data_uploader.py` on a 600s interval. Launched when `status/app_is_open.open = true`.
- `motion_capture.py` — PIR-triggered photo capture. Uses a 6.5s sustained-motion timer to filter false positives. Starts/stops camera only during capture to save power. Launched when `config/settings.motion_capture_enabled = true`.
- `data_uploader.py` — Batch uploads local CSV energy logs to Firestore. Called by system_updater.py (not directly by master_control).
- `data_logger.py` — Reads ADS1115 ADC values, appends to local CSV. Likely run via cron (not managed by master_control).

**Inactive/utility scripts (not part of live system):**
- `config_updater.py` — Older version of system_updater.py (superseded, code is duplicated)
- `cpu_logger.py` — CPU monitoring utility (standalone test tool)
- `motion_test.py` — PIR sensor pulse width logger (standalone test tool)
- `ADS1115_Quicktest.py` — ADC hardware test (standalone test tool)
- `config.py` — Intended shared config but barely used by other scripts

**Mutual exclusion logic:** Camera server and motion capture cannot run simultaneously (camera hardware conflict). Master control handles this — streaming takes priority and pauses motion capture, which auto-resumes when streaming stops.

### Flutter Desktop App (`bird_feeder_app/`)
Built with Flutter, uses Firebase (Firestore + Storage) for real-time data.

**Screens:**
- `home_screen.dart` — Shell with bottom nav, app bar with online status dot + battery level
- `gallery_screen.dart` — Tabbed view of motion captures and snapshots, with selection/deletion and bird identification
- `catalog_screen.dart` — Bird species catalog sorted by sighting count
- `live_feed_screen.dart` — TCP socket client for camera stream, snapshot button
- `system_screen.dart` — Tabs container for settings and stats
- `settings_screen.dart` — Camera config management via Firestore
- `stats_screen.dart` — Energy charts (battery %, solar voltage) using fl_chart

**Key files:**
- `main.dart` — Firebase init + AppLifecycleMonitor that sets `status/app_is_open` and disables streaming on close
- `globals.dart` — Single mutable global for Pi IP address (fragile, needs improvement)
- `models/` — Data classes for camera_settings, energy_data, sighting

### Firebase Structure
**Firestore paths:**
- `status/heartbeat` — Pi online status + IP address
- `status/streaming_enabled` — Controls camera server lifecycle
- `status/app_is_open` — Controls system_updater lifecycle
- `config/settings` — Camera/motion config (resolution, framerate, motion_capture_enabled)
- `logs/motion_captures/data` — Motion-triggered photo metadata
- `logs/snapshots/data` — Manual snapshot metadata
- `logs/energy/data` — Battery/solar voltage time series
- `logs/sightings/data` — Bird sighting catalog data

**Storage bucket:** `birdfeeder-b6224.firebasestorage.app`
- `media/sightings/` — Motion capture photos
- `media/snapshots/` — Manual snapshots

## Known Bugs
1. `camera_server.py` line 171: `tracebox.format_exc()` should be `traceback.format_exc()` — will crash on snapshot errors
2. `master_control.py` line 396: Missing f-prefix on f-string — heartbeat log prints literal `{current_ip}` instead of actual IP

## Key Issues for V2 Improvement
1. **Massive config duplication** — Firebase credentials, paths, and init logic copy-pasted across 7+ scripts. `config.py` exists but nothing uses it.
2. **Script duplication** — `system_updater.py` and `config_updater.py` are near-identical (config_updater is the unused older version).
3. **Inconsistent logging** — Mix of print() statements and Python logging module across scripts.
4. **No shared Firebase initialization** — Each script creates its own Firebase app instance, wasteful on Pi Zero 2 W's limited RAM.
5. **Fragile process management** — PID files + SIGKILL with hardcoded sleeps in master_control.
6. **Flutter globals** — Raw mutable global for Pi IP, Firestore paths as scattered string literals.
7. **No error recovery** — If motion_capture or camera_server crash, master_control doesn't detect or restart them.

## V2 Development Approach
Incremental improvement, not full rewrite. Keep the current system working while improving one piece at a time. Each change should be tested on the Pi before moving to the next.

**Priority order:**
1. Create proper shared config module (centralize all paths, credentials, Firebase init)
2. Fix known bugs (traceback typo, f-string prefix)
3. Consolidate duplicated scripts
4. Add proper logging throughout
5. Improve process management (crash detection, auto-restart)
6. Clean up Flutter app (centralized constants, state management, network/UI separation)

## Development Environment
- Pi code: Edited via Samba network share from dev machine, tested by SSH'ing into Pi and running scripts
- Flutter app: Developed and tested locally on dev machine
- Pi path: `/home/wyattshore/Birdfeeder/`
- Service account: `birdfeeder-sa.json` (do NOT commit this to git)
- Python environment: Virtual environment on the Pi (scripts use sys.executable)
