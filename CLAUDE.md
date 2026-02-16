# Smart Birdfeeder Project

## Project Overview
A solar-powered smart birdfeeder built on a Raspberry Pi Zero 2 W with an RPi Camera Module 3 Wide. The system detects birds via a PIR motion sensor, captures photos, and uploads them to Firebase. A Flutter desktop app provides a dashboard for viewing sightings, live camera feed, energy stats, and system configuration.

## Repository Structure
```
birdfeeder/
├── CLAUDE.md          # This file
├── README.md          # Project overview for GitHub
├── .gitignore         # Git exclusions
├── raspberry_pi/      # Pi-side Python code
│   ├── PythonScripts/ # All Python scripts
│   └── birdfeeder-sa.json  # Firebase service account (NOT in git)
└── app/               # Flutter desktop application
    └── lib/           # Flutter source code
```

## Hardware
- **Raspberry Pi Zero 2 W** (main compute, limited RAM)
- **RPi Camera Module 3 Wide** (4608x2592 max resolution)
- **PIR motion sensor** (GPIO pin 4, prone to false positives from electrical/thermal interference)
- **ADS1115 ADC module** (I2C, address 0x48) for voltage monitoring
- **Two solar panels + single-cell LiPo battery** (3.2V-4.2V range)
- **Voltage divider ratios:** Solar (A0) = 2.419, Battery (A1) = 1.435

**Key hardware constraint:** Battery life is the most critical resource. WiFi draws significant power, so optimization for low-power operation is essential.

## Current Architecture (V1)

### Pi-Side Code (`raspberry_pi/PythonScripts/`)
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

### Flutter Desktop App (`app/`)
Built with Flutter, uses Firebase (Firestore + Storage) for real-time data.

**Current screens:**
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

## Known Bugs (V1)
1. `camera_server.py` line 171: `tracebox.format_exc()` should be `traceback.format_exc()` — will crash on snapshot errors
2. `master_control.py` line 396: Missing f-prefix on f-string — heartbeat log prints literal `{current_ip}` instead of actual IP

## Key Issues for V2 Improvement

### Code Quality Issues
1. **Massive config duplication** — Firebase credentials, paths, and init logic copy-pasted across 7+ scripts. `config.py` exists but nothing uses it.
2. **Script duplication** — `system_updater.py` and `config_updater.py` are near-identical (config_updater is the unused older version).
3. **Inconsistent logging** — Mix of print() statements and Python logging module across scripts.
4. **No shared Firebase initialization** — Each script creates its own Firebase app instance, wasteful on Pi Zero 2 W's limited RAM.
5. **Fragile process management** — PID files + SIGKILL with hardcoded sleeps in master_control.
6. **Flutter globals** — Raw mutable global for Pi IP, Firestore paths as scattered string literals.
7. **No error recovery** — If motion_capture or camera_server crash, master_control doesn't detect or restart them.

### Architecture Issues
1. **Suboptimal file structure** — Current organization could be simplified and made more logical
2. **WiFi always-on** — Constant WiFi broadcasting drains battery significantly. Should explore periodic sync or on-demand connectivity.
3. **False positive filtering** — PIR sensor triggers on electrical/thermal interference. 6.5s threshold helps but not sufficient.

## V2 Development Plan

### Phase 1: Code Cleanup & Architecture Foundation
**Goal:** Clean, maintainable baseline with proper structure before adding features.

**Tasks:**
1. **Create shared config module**
   - Centralize all Firebase credentials, paths, and constants
   - Single Firebase initialization function used by all scripts
   - Update all scripts to import from shared config

2. **Fix known bugs**
   - Fix `traceback` typo in camera_server.py
   - Fix f-string in master_control.py

3. **Consolidate duplicated code**
   - Remove `config_updater.py` (superseded by system_updater.py)
   - Extract common normalization logic into shared utilities

4. **Standardize logging**
   - Implement consistent Python logging throughout all scripts
   - Remove all print() statements in favor of proper logging

5. **Optimize Firebase usage**
   - Single Firebase app initialization across all scripts
   - Reduce redundant connections

6. **Improve process management**
   - Add crash detection and auto-restart capability to master_control
   - Better PID file handling with validation

7. **Clean up Flutter app**
   - Centralize Firestore paths as constants
   - Replace globals.dart with proper state management
   - Separate network logic from UI in live_feed_screen

8. **Optimize file structure**
   - Reorganize scripts into logical groupings (core, utilities, hardware)
   - Remove dead/test code from production directory
   - Document what each script does and when it runs

### Phase 2: Power Optimization & Smart Upload
**Goal:** Maximize battery life through intelligent batching and upload scheduling.

**Battery conservation strategy:**
WiFi remains on for system functionality, but we reduce power consumption through smarter upload patterns and operational scheduling rather than WiFi toggling (which adds significant complexity for uncertain gains).

**New motion capture workflow:**
1. **Local queueing:**
   - PIR triggers → Pi captures image → saves to local queue folder (no immediate upload)
   - Images accumulate throughout the day in `/home/wyattshore/upload_queue/`
   - No network activity during capture (saves power)

2. **Batch upload on app open:**
   - When app opens → `system_updater.py` triggers batch upload process
   - All queued images uploaded together (more efficient than individual uploads)
   - Queue cleared after successful upload
   - Energy data also uploaded in same batch window

3. **Additional power optimizations:**
   - Reduce heartbeat frequency (currently 30s, could increase to 60-120s)
   - Optimize Firestore listener efficiency (batch reads vs. polling)
   - Review `data_logger.py` cron frequency (reduce if logging too often)
   - Add "Low Power Mode" toggle in app (disables live streaming, reduces upload frequency)

4. **Smart scheduling (future enhancement):**
   - Consider uploading only during peak solar hours (10am-4pm)
   - Schedule heavy operations when battery is charging
   - Measure actual power draw to identify optimization targets

**Why this approach vs. WiFi toggling:**
- WiFi on/off adds complexity (waking Pi remotely is non-trivial)
- Unknown ROI without power measurements
- Batching gives most of the benefit with much simpler implementation
- Can revisit WiFi toggling in V3 if measurements show it's the dominant drain

### Phase 3: Motion Detection & CV Filtering
**Goal:** Reduce false positives through configurable thresholds and lightweight computer vision filtering.

**Current issue:** PIR sensor triggers on electrical interference and thermal fluctuations, not just actual motion.

**Implementation approach:**

**Part A: Configurable motion threshold**
- Make 6.5s threshold adjustable via app settings
- Allow experimentation to find optimal value for deployment location
- Store threshold in Firestore `config/settings`
- Track false positive rate over time for auto-tuning insights

**Part B: Local CV filtering (before batch upload)**
This runs on the Pi when the batch upload is triggered (app opens), NOT during individual captures. This approach:
- Keeps captures fast and low-power (no CV overhead during motion detection)
- Filters the entire queue in one pass when WiFi is already active
- Remains completely free (no cloud function costs)

**CV Filter workflow:**
1. App opens → triggers batch upload process
2. Before uploading, iterate through queued images
3. For each image:
   - Run lightweight CV analysis (background subtraction vs. empty feeder reference frame)
   - Calculate difference score (how much changed from empty feeder)
   - If score below threshold → likely false positive, delete locally (don't upload)
   - If score above threshold → real motion detected, proceed with upload
4. Upload only validated images to Firebase Storage
5. Log metadata to Firestore for kept images

**CV techniques to test (in order of computational cost):**
1. **File size check** (cheapest) — Empty feeder photos are typically smaller
2. **Simple background subtraction** (OpenCV) — Compare to reference frame, count changed pixels
3. **Edge detection + blob analysis** — Detect presence of discrete objects
4. **Brightness/contrast deltas** — Bird creates different lighting patterns

**Testing & validation phase (CRITICAL):**
Before deploying CV filter to production, we need rigorous testing:

1. **Data collection:**
   - Capture 100-200 test images (mix of real birds and false positives)
   - Manually label each as "bird" or "false positive"
   - Store in test dataset folder with labels

2. **Algorithm tuning:**
   - Test different CV techniques and threshold values
   - Measure precision (% of detected birds that are real) and recall (% of real birds detected)
   - **Goal: 0% false negatives (never delete a real bird photo)**
   - Acceptable false positives: <20% slip through (we'll manually delete later)

3. **Performance validation:**
   - Measure CPU usage during batch filtering
   - Measure time to process typical queue size (e.g., 50 images)
   - Ensure processing completes in <30 seconds to avoid blocking uploads
   - Monitor CPU temperature (thermal throttling concern on Pi Zero 2 W)

4. **A/B testing:**
   - Run system with CV filter for 1 week
   - Compare: images captured vs. images uploaded vs. real bird sightings
   - Validate no birds were incorrectly filtered out

**Part C: Video capture option (future enhancement)**
- Add configurable option to capture brief video instead of/in addition to photo
- Could help with motion blur issues
- Could provide richer data for CV analysis
- Defer until after CV filter is proven and stable

**Success criteria:**
- Zero false negatives (no bird photos deleted)
- 50%+ reduction in false positive uploads
- <10% CPU usage increase during batch processing
- No thermal throttling or system instability

### Phase 4: Camera Control & Image Quality
**Goal:** Give user control over camera settings to improve photo quality.

**Current issues:**
- Motion blur from fast bird movement
- Focus issues (birds often out of focus)
- No exposure control

**Proposed settings (via app UI):**
1. **Exposure control:**
   - Manual exposure time slider
   - Auto-exposure with exposure compensation

2. **Focus control:**
   - Autofocus mode (continuous, single-shot)
   - Manual focus distance slider
   - Pre-focus on feeder location option

3. **Shutter speed:**
   - Faster shutter to reduce motion blur
   - Trade-off with light sensitivity

4. **Other camera parameters:**
   - ISO/gain control
   - White balance
   - Contrast/saturation adjustments

**Implementation:**
- Research Picamera2 API capabilities for available controls
- Create settings UI in Flutter app
- Sync settings via Firestore to motion_capture.py and camera_server.py
- Add settings persistence and defaults

### Phase 5: App Redesign - Activity & Catalog
**Goal:** Restructure app to focus on bird activity tracking and species profiles.

**New information architecture:**

**Activity Screen (replaces Gallery):**
- Shows recent unidentified sightings with date/time
- Grid layout similar to current gallery
- Tap a sighting to open detail view
- From detail view, can assign to species (moves to Catalog)
- Can delete if false positive

**Catalog Screen (enhanced):**
- List of all identified bird species
- Sorted by sighting count or most recent
- Tap species to open profile

**Bird Profile Screen (new):**
- Species name and photo grid of all sightings
- Stats:
  - Total sightings count
  - Average time of day (histogram or chart)
  - First seen / last seen dates
  - Frequency (sightings per day/week)
- Brief species description (manually entered or API lookup?)
- Edit/delete species

**Data model changes:**
- Add `species_id` and `identified` flag to sighting documents
- Create `species` collection with metadata
- Migrate existing catalog structure

### Phase 6: UI Polish & Aesthetics
**Goal:** Improve visual design and user experience.

**Areas for improvement:**
1. Color scheme and theming
2. Icons and visual hierarchy
3. Animations and transitions
4. Loading states and error handling
5. Responsive layout improvements
6. Better data visualization (charts, graphs)

**Defer details until Phases 1-5 complete** — will have better sense of final UI structure.

---

## Additional Ideas & Considerations

### Potential Future Features (Beyond V2 Scope)
- **Automatic species identification:** Use ML model (on-device or cloud API) to suggest species
- **Feeding schedule tracking:** Correlate sightings with refill times
- **Weather integration:** Track how weather affects bird activity
- **Multi-feeder support:** Scale to multiple Pi units
- **Audio detection:** Microphone to identify bird calls
- **Community features:** Share sightings, compare with other users
- **Time-lapse mode:** Create daily/weekly videos from captures

### Technical Debt to Address
- Add unit tests for critical Pi-side functions
- Document API contracts between Pi and app
- Set up CI/CD for automated testing
- Create development/staging Firebase environment
- Add proper error reporting/crash analytics

### Hardware Upgrades to Consider
- Better PIR sensor with lower false positive rate
- Capacitive proximity sensor as secondary trigger
- Larger battery or more efficient solar panels
- Pi Zero 2 W alternative with better power management

---

## Development Environment

### Setup
- **Pi code:** Edited locally in VS Code, pushed to GitHub, pulled on Pi via SSH for testing
- **Flutter app:** Developed and tested locally on Windows machine
- **Version control:** Single GitHub repo with both Pi and app code
- **Pi deployment path:** `/home/wyattshore/Birdfeeder/`
- **Service account:** `birdfeeder-sa.json` (excluded from git, required on Pi)
- **Python environment:** Virtual environment on the Pi (scripts use sys.executable)

### Workflow
1. Edit code locally in VS Code with Claude Code
2. Commit and push changes to GitHub
3. SSH into Pi: `ssh pi@<ip-address>`
4. Pull latest changes: `cd ~/Birdfeeder && git pull`
5. Restart affected services (e.g., `sudo systemctl restart birdfeeder`)
6. Monitor logs and test functionality
7. Iterate as needed

### Testing Strategy
- **Pi scripts:** Test on actual hardware (camera, PIR, ADC required)
- **Flutter app:** Mock Firebase data for offline development when needed
- **Integration:** Test full system with Pi running and app connected
- **Power testing:** Measure battery drain under various WiFi scenarios

---

## Notes for Claude Code

- This is a real IoT system running on constrained hardware
- Battery life is THE critical constraint — always consider power impact
- User is learning, so explain architectural decisions
- Test incrementally — don't refactor everything at once
- Each phase should leave the system in a working state
- Prioritize Phase 1 (foundation) before adding new features
- User is open to suggestions but wants to understand trade-offs
