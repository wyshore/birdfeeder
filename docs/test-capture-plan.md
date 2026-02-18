# Test Capture Feature Plan

## Goal
Add a "test capture" tool to the app so the user can preview what the camera sees with current settings. This is primarily for tuning camera controls (brightness, contrast, shutter speed, etc.) which may need to vary by day based on lighting conditions. The feature should allow taking a quick test photo and comparing a few recent captures side-by-side.

## How It Works Today

The existing **snapshot command** already does most of what we need:
- The app sends `0x01 0x01` over the TCP socket to `camera_server.py`
- The Pi captures a high-res JPEG from the main camera stream
- It uploads to Firebase Storage (`media/snapshots/`) and logs metadata to `logs/snapshots/data`
- The app shows a toast "Snapshot requested"

**Problem:** This only works when the live stream is active (TCP connection required), which means the camera server must be running and streaming. That's battery-expensive. Also, snapshots taken this way go into the permanent `logs/snapshots/data` collection and show up on the Activity screen as sightings to identify.

## Proposed Approach

### Option A: Firestore-Triggered Test Capture (Recommended)

A lightweight approach that works **without the live stream running**:

1. **App** writes a request to Firestore: `status/test_capture` → `{ requested: true, timestamp: ... }`
2. **Pi** (via `system_updater.py` which already polls Firestore) detects the request
3. Pi powers on the camera, applies current settings from `config/settings`, takes one photo
4. Uploads to a **temporary** storage path: `media/test_captures/{timestamp}.jpg`
5. Writes result back: `status/test_capture` → `{ requested: false, imageUrl: "...", timestamp: ..., resolution: "..." }`
6. **App** is listening on `status/test_capture` — when `imageUrl` updates, it displays the photo

**Advantages:**
- Works when streaming is OFF (no TCP connection needed)
- Minimal battery cost — camera on for ~2 seconds per capture
- Uses the real motion capture camera settings (not the lower stream resolution)
- Clean separation from permanent sighting data

## Implementation Details

### Pi Side

**New listener in `system_updater.py`** (already runs a Firestore polling loop):

```python
def check_test_capture():
    """Check if app has requested a test capture."""
    doc = db.document("status/test_capture").get()
    data = doc.to_dict() or {}
    if data.get("requested", False):
        take_test_capture()

def take_test_capture():
    """Take a single test photo and upload it."""
    # 1. Read current camera settings from config/settings
    # 2. Initialize camera with those settings
    # 3. Wait for camera warmup (~1-2s)
    # 4. Capture single JPEG
    # 5. Upload to Firebase Storage: media/test_captures/{timestamp}.jpg
    # 6. Update Firestore: status/test_capture → { requested: false, imageUrl, resolution, timestamp }
    # 7. Clean up: delete old test captures from Storage (keep last 5)
    # 8. Stop camera
```

**Camera settings applied:** Should read from the same `config/settings` doc that the camera controls screen writes to, so the test photo reflects whatever the user just changed.

**Cleanup:** Auto-delete test captures older than the most recent 5 from Firebase Storage to avoid accumulating junk.

### App Side

**Modify `live_feed_screen.dart`** to add a test capture section:

#### Behavior
1. **"Take Test Photo" button** → writes `{ requested: true }` to `status/test_capture`
2. Button shows a spinner while waiting (listen for `requested` to become `false`)
3. When result arrives, display the photo in the large preview area
4. **Recent captures row** — StreamBuilder on a `status/test_captures/history` subcollection (last 5), displayed as clickable thumbnails
5. Tapping a thumbnail swaps it into the large preview for comparison
6. **"Clear test captures"** button deletes the history subcollection and storage files

#### Firestore Structure
```
status/test_capture
  ├── requested: bool
  └── timestamp: Timestamp

logs/test_captures/history/{auto-id}
  ├── imageUrl: string
  ├── resolution: string
  ├── timestamp: Timestamp
  └── storagePath: string (for cleanup)
```

### Edge Cases to Handle

- **Pi offline:** Button should check heartbeat first and show "Pi is offline" if no recent heartbeat
- **Rapid tapping:** Debounce — ignore new requests while one is pending
- **Camera busy:** If motion_capture or streaming is using the camera, queue or reject gracefully
- **system_updater polling interval:** Currently polls every N seconds. Test capture response time depends on this interval. May want to reduce interval temporarily or add a dedicated short-poll loop when a request is pending
