# Smart Birdfeeder Project

## Quick Overview
Solar-powered IoT birdfeeder on Raspberry Pi Zero 2 W with camera, PIR motion sensor, and Flutter desktop app. Captures bird photos on motion, uploads to Firebase, displays in app with live streaming, energy monitoring, and species catalog.

## Repository Structure
- `pi/` — Pi-side Python code (master_control orchestrates child processes)
- `app/` — Flutter desktop application
- `docs/` — Detailed documentation and phase plans

## Active Pi Scripts (managed by master_control.py)
- `master_control.py` — Main orchestrator, heartbeat, process lifecycle
- `camera_server.py` — TCP streaming server (port 8000)
- `system_updater.py` — Config sync + data upload scheduler
- `motion_capture.py` — PIR-triggered photo capture (6.5s threshold)
- `data_uploader.py` — Batch Firestore upload (called by system_updater)
- `data_logger.py` — ADC logging (cron job)

## V2 Development Phases (see `docs/`)
1. Phase 1: Cleanup & Foundation (complete)
2. Phase 2: Power Optimization & Batch Upload
3. Phase 3: CV Filtering & Motion Tuning
4. Phase 4: Camera Controls 
5. Phase 5: App Redesign (Activity/Catalog)
6. Phase 6: UI Polish

**Read the relevant phase doc when starting work on that phase.**

## Firebase Structure
- `status/heartbeat` — Pi online, IP address
- `status/streaming_enabled` — Camera server control
- `status/app_is_open` — System_updater control
- `config/settings` — All config (resolution, framerate, motion_capture_enabled)
- `logs/motion_captures/data`, `logs/snapshots/data` — Photo metadata
- `logs/energy/data` — Battery/solar voltage
- Storage: `birdfeeder-b6224.firebasestorage.app`

## Hardware Constraints
- **Battery life is the critical resource** — Pi Zero 2 W + WiFi + camera
- PIR sensor: GPIO 4 (prone to false positives from interference)

## Development Workflow
- Edit locally, push to GitHub, SSH to Pi and pull to test
- Pi path: `/home/wyattshore/Birdfeeder/`
- Service account: `birdfeeder-sa.json` (excluded from git)
- Always test changes incrementally

## Notes for Claude Code
- User is learning — explain architectural decisions
- Test each change before moving to next
- Battery life impact must be considered for all Pi changes
- Keep the system working at each step
