# System Architecture - Smart Birdfeeder

## Hardware Components
- **Raspberry Pi Zero 2 W** — Main compute (512MB RAM, limited resources)
- **RPi Camera Module 3 Wide** — 4608x2592 max resolution
- **PIR Motion Sensor** — GPIO pin 4 (prone to false positives from electrical/thermal interference)
- **ADS1115 ADC** — I2C address 0x48, reads battery + solar voltage
- **Solar panels + LiPo battery** — 3.2V-4.2V range, voltage dividers (Solar A0: 2.419x, Battery A1: 1.435x)

## Pi-Side Architecture

### Process Management
`master_control.py` is the always-on orchestrator. It:
- Listens to Firestore documents for state changes
- Launches/stops child processes based on Firestore flags
- Sends heartbeat with IP every 30s to `status/heartbeat`
- Manages mutual exclusion (camera server and motion capture can't run together)

### Child Processes (Managed by master_control)
1. **camera_server.py** — Launched when `status/streaming_enabled.enabled = true`
   - TCP server on port 8000
   - Hardware-encoded JPEG stream (lores 640x360 @ 10fps)
   - High-res snapshot capture (2560x1440)
   - Uploads snapshots to Firebase Storage

2. **system_updater.py** — Launched when `status/app_is_open.open = true`
   - Listens to `config/settings` for changes
   - Normalizes config and saves to `local_app_settings.json`
   - Runs `data_uploader.py` on 600s interval

3. **motion_capture.py** — Launched when `config/settings.motion_capture_enabled = true`
   - Monitors PIR sensor (GPIO 4)
   - 6.5s sustained motion threshold (filters false positives)
   - Powers camera on for capture, then off (battery saving)
   - Uploads to Firebase Storage, logs to `logs/motion_captures/data`

### Background Jobs
- **data_logger.py** — Runs via cron, reads ADS1115, appends to local CSV
- **data_uploader.py** — Called by system_updater, batch uploads CSV to Firestore

### Unused Scripts
- `config_updater.py` — Old version of system_updater (to be removed)
- `cpu_logger.py`, `motion_test.py`, `ADS1115_Quicktest.py` — Test utilities

## Flutter App Architecture

### Screens
- `home_screen.dart` — Nav shell with status bar (online dot, battery %)
- `gallery_screen.dart` — Motion captures + snapshots with identification
- `catalog_screen.dart` — Bird species list
- `live_feed_screen.dart` — TCP client for camera stream
- `system_screen.dart` — Settings + Stats tabs
- `settings_screen.dart` — Camera config via Firestore
- `stats_screen.dart` — Energy charts (fl_chart)

### Key Components
- `main.dart` — Firebase init, AppLifecycleMonitor sets `status/app_is_open`
- `globals.dart` — Mutable global for Pi IP (to be replaced)
- `models/` — Data classes (camera_settings, energy_data, sighting)

## Firebase Structure

### Firestore Collections
- `status/heartbeat` — Pi online status + IP
- `status/streaming_enabled` — Camera server control
- `status/app_is_open` — System_updater control
- `config/settings` — All config (resolution, framerate, motion_capture_enabled)
- `logs/motion_captures/data` — Motion photo metadata
- `logs/snapshots/data` — Manual snapshot metadata
- `logs/energy/data` — Battery/solar time series
- `logs/sightings/data` — Bird catalog (to be restructured in Phase 5)

### Firebase Storage
Bucket: `birdfeeder-b6224.firebasestorage.app`
- `media/sightings/` — Motion captures
- `media/snapshots/` — Manual snapshots

## Data Flow Examples

### Motion Capture Flow (Current)
1. PIR detects motion → `motion_capture.py` starts 6.5s timer
2. If motion sustained → capture photo, save locally
3. Upload to Storage, create Firestore log entry
4. App queries `logs/motion_captures/data` → displays in gallery

### Live Streaming Flow
1. User opens Live Feed screen → app sets `status/streaming_enabled.enabled = true`
2. `master_control.py` sees change → launches `camera_server.py`
3. App connects to TCP port 8000, receives JPEG frames
4. User closes screen → app sets enabled = false → camera_server stopped

### Config Sync Flow
1. User changes setting in app → writes to `config/settings`
2. `system_updater.py` (running when app open) sees change via Firestore listener
3. Normalizes config, saves to `local_app_settings.json`
4. Affected scripts read local config on next run

## Power Considerations
**Battery life is the critical constraint.** Major power draws:
- WiFi transmit/receive
- Camera sensor (especially during capture)
- PIR sensor active monitoring
- CPU during processing

Current optimizations:
- Camera powers off between captures
- System_updater only runs when app is open
- Motion capture stops when streaming active

Future optimizations (Phase 2):
- Batch uploads instead of immediate
- Reduce heartbeat frequency
- Low power mode toggle
