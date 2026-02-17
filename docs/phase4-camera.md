# Phase 4: Camera Control & Image Quality

**Goal:** Give user control over camera settings to improve photo quality.

## Current Issues
- Motion blur from fast bird movement
- Focus issues
- No exposure control

## Proposed Camera Settings (via App UI)

### 1. Exposure Control
- Manual exposure time slider (microseconds)
- Auto-exposure with compensation (-2 to +2 EV)

### 2. Focus Control
- Autofocus mode selector (continuous, single-shot, manual)
- Manual focus distance slider (meters)
- "Pre-focus on feeder" button (sets fixed distance)

### 3. Shutter Speed
- Fast shutter slider (for motion blur reduction)
- Trade-off: requires more light or higher ISO

### 4. Other Parameters
- ISO/gain slider
- White balance presets (auto, daylight, cloudy, shade)
- Contrast/saturation/sharpness sliders

## Implementation Steps

### 1. Research Picamera2 API
- Read Picamera2 docs for available controls
- Test controls in isolation on Pi
- Document which settings help with motion blur/focus

### 2. Extend Firestore config/settings
Add new fields for camera controls (with defaults).

### 3. Update motion_capture.py and camera_server.py
- Read camera settings from config
- Apply settings via `picam2.set_controls()`
- Handle invalid values gracefully

### 4. Create Camera Settings UI (Flutter)
New screen or section in `settings_screen.dart`:
- Sliders for numeric values
- Dropdowns for mode selections
- "Reset to defaults" button
- Live preview feedback (if streaming active)

### 5. Test & Tune
- Capture test shots with various settings
- Find optimal values for motion blur reduction
- Document recommended settings in app UI

## Success Criteria
✓ User can adjust exposure, focus, shutter, ISO
✓ Settings sync to Pi in real-time
✓ Motion blur and focus issues improved
✓ Settings persist across restarts
