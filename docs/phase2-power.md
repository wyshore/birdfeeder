# Phase 2: Power Optimization & Smart Upload

**Goal:** Maximize battery life through intelligent batching and upload scheduling.

## Battery Conservation Strategy
WiFi stays on, but we reduce power through smarter upload patterns rather than WiFi toggling (complexity not worth ROI).

## New Motion Capture Workflow

### 1. Local Queueing
- PIR triggers → capture → save locally (no upload)
- Images accumulate throughout the day
- No network activity during capture

### 2. Batch Upload on App Open
- When app opens → `system_updater.py` triggers batch upload
- Upload all queued images together (efficient)
- Clear queue after success
- Energy data uploads in same window

### 3. Code Changes Needed
**motion_capture.py:**
- Disable immediate `upload_and_log()` call
- Just save to queue folder

**system_updater.py:**
- Add new function `batch_upload_queue()` on startup
- Iterate queue folder
- Upload each image
- Create Firestore log entries
- Delete local files on success

**Flutter app:**
- No changes needed (app already triggers system_updater via app_is_open)

## Additional Optimizations
- Reduce heartbeat frequency: 30s → 60-120s (edit master_control.py)

## Testing
- Open app, verify batch upload works
- Check queue is cleared
- Measure: captures per day vs. uploads (should match)

## Success Criteria
✓ Images queue locally, no immediate uploads
✓ Batch upload works reliably on app open
✓ No data loss
✓ Reduced network activity = power savings
