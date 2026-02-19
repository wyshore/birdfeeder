# -*- coding: utf-8 -*-
"""
SYSTEM UPDATER - Config Listener & Data Upload Controller

Monitors Firestore config/settings document and:
1. Normalizes incoming camera settings to local JSON schema
2. Saves settings to local config file for camera_server
3. Runs data_uploader.py immediately on startup and periodically (every 10 minutes)

Active while app is open (controlled by master_control.py).
"""

import os
import sys
import signal
import json
import time
import traceback
import threading
import subprocess
from typing import Dict, Any

# Import shared configuration
import shared_config as config

# Setup logging
logger = config.setup_logging("system_updater")

# Firebase Admin SDK imports
try:
    from firebase_admin import firestore
except ImportError:
    logger.error("FATAL: Firebase Admin SDK not found. Install: pip install firebase-admin")
    sys.exit(1)

# Global state
db = None
storage_bucket = None
main_thread_event = threading.Event()
data_upload_stop_flag = threading.Event()
is_test_capturing = False


# ============================================================================
# LOCAL CONFIG MANAGEMENT
# ============================================================================

def load_local_config() -> Dict[str, Any]:
    """
    Load settings from local JSON file.

    Returns:
        Dictionary of camera settings, or defaults if file doesn't exist
    """
    if os.path.exists(config.LOCAL_CONFIG_FILE):
        try:
            with open(config.LOCAL_CONFIG_FILE, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Failed to load local config: {e}. Using defaults")

    # Default settings
    return {
        "stream_resolution": list(config.DEFAULT_STREAM_RESOLUTION),
        "snapshot_resolution": list(config.DEFAULT_SNAPSHOT_RESOLUTION),
        "motion_capture_resolution": list(config.DEFAULT_CAPTURE_RESOLUTION),
        "stream_framerate": config.DEFAULT_FRAMERATE,
        "motion_capture_enabled": False,
        "motion_threshold_seconds": config.MIN_PULSE_DURATION,
        "capture_mode": config.DEFAULT_CAPTURE_MODE,
        "photo_capture_interval": config.DEFAULT_PHOTO_INTERVAL,
        "video_duration_mode": config.DEFAULT_VIDEO_DURATION_MODE,
        "video_fixed_duration": config.DEFAULT_VIDEO_FIXED_DURATION,
        "camera_controls": dict(config.DEFAULT_CAMERA_CONTROLS),
    }


def save_local_config(settings: Dict[str, Any]) -> None:
    """
    Save settings to local JSON file.

    Args:
        settings: Dictionary of camera settings to save
    """
    try:
        with open(config.LOCAL_CONFIG_FILE, 'w') as f:
            json.dump(settings, f, indent=4)

        logger.info("=== NEW SETTINGS SAVED ===")
        logger.info(f"File: {config.LOCAL_CONFIG_FILE}")
        logger.info(f"Stream: {settings.get('stream_resolution')} @ {settings.get('stream_framerate')}fps")
        logger.info(f"Snapshot: {settings.get('snapshot_resolution')}")
        logger.info(f"Motion capture: {settings.get('motion_capture_resolution')}")
        logger.info(f"Camera controls: {settings.get('camera_controls')}")

    except Exception as e:
        logger.error(f"Failed to save local config: {e}")
        traceback.print_exc()


def normalize_settings(doc_dict: Dict[str, Any]) -> Dict[str, Any]:
    """
    Normalize Firestore config document to camera_server schema.

    Handles different input formats and returns consistent output.

    Args:
        doc_dict: Raw Firestore document data

    Returns:
        Normalized settings dictionary
    """
    out = {}

    def parse_resolution(val):
        """Parse resolution from various formats."""
        if isinstance(val, (list, tuple)) and len(val) >= 2:
            return [int(val[0]), int(val[1])]
        if isinstance(val, str) and 'x' in val:
            try:
                w, h = val.lower().split('x')
                return [int(w), int(h)]
            except Exception:
                return None
        return None

    # Stream resolution
    res = doc_dict.get("resolution") or doc_dict.get("stream_resolution")
    parsed = parse_resolution(res)
    if parsed:
        out["stream_resolution"] = parsed

    # Snapshot resolution (fallback to stream if not specified)
    snap = doc_dict.get("snapshot_resolution")
    parsed_snap = parse_resolution(snap) or out.get("stream_resolution")
    if parsed_snap:
        out["snapshot_resolution"] = parsed_snap

    # Motion capture resolution
    mc_res = doc_dict.get("motion_capture_resolution")
    parsed_mc = parse_resolution(mc_res)
    if parsed_mc:
        out["motion_capture_resolution"] = parsed_mc

    # Motion capture enabled flag
    if "motion_capture_enabled" in doc_dict:
        out["motion_capture_enabled"] = bool(doc_dict["motion_capture_enabled"])

    # Motion duration threshold (seconds)
    motion_thresh = doc_dict.get("motion_threshold_seconds")
    if motion_thresh is not None:
        try:
            val = float(motion_thresh)
            if 1.0 <= val <= 20.0:
                out["motion_threshold_seconds"] = val
        except (TypeError, ValueError):
            pass

    # Capture mode: 'photo' | 'video'
    capture_mode = doc_dict.get("capture_mode")
    if capture_mode in ('photo', 'video'):
        out["capture_mode"] = capture_mode

    # Photo capture interval (seconds between photos)
    photo_interval = doc_dict.get("photo_capture_interval")
    if photo_interval is not None:
        try:
            val = float(photo_interval)
            if 0.5 <= val <= 60.0:
                out["photo_capture_interval"] = val
        except (TypeError, ValueError):
            pass

    # Video duration mode: 'fixed' | 'motion'
    video_duration_mode = doc_dict.get("video_duration_mode")
    if video_duration_mode in ('fixed', 'motion'):
        out["video_duration_mode"] = video_duration_mode

    # Video fixed duration (seconds)
    video_fixed_duration = doc_dict.get("video_fixed_duration")
    if video_fixed_duration is not None:
        try:
            val = float(video_fixed_duration)
            if 1.0 <= val <= 120.0:
                out["video_fixed_duration"] = val
        except (TypeError, ValueError):
            pass

    # Stream framerate
    if "stream_framerate" in doc_dict:
        try:
            out["stream_framerate"] = int(doc_dict["stream_framerate"])
        except Exception:
            pass

    # --- Camera Controls ---
    # Map Firestore field names to Picamera2 control names.
    # Start from defaults, then override with any values from Firestore.
    controls = dict(config.DEFAULT_CAMERA_CONTROLS)

    # Autofocus mode: "manual"=0, "single"=1, "continuous"=2
    AF_MODE_MAP = {"manual": 0, "single": 1, "continuous": 2}
    af = doc_dict.get("af_mode")
    if af is not None:
        controls["AfMode"] = AF_MODE_MAP.get(af, af) if isinstance(af, str) else int(af)

    # Manual focus position (0.0 = infinity, larger = closer)
    lens_pos = doc_dict.get("lens_position")
    if lens_pos is not None:
        controls["LensPosition"] = float(lens_pos)

    # Exposure: 0 or absent = auto, >0 = manual (microseconds)
    exp = doc_dict.get("exposure_time")
    if exp is not None:
        exp_val = int(exp)
        if exp_val > 0:
            controls["AeEnable"] = False
            controls["ExposureTime"] = exp_val
        else:
            controls["AeEnable"] = True
            controls.pop("ExposureTime", None)

    # Analogue gain (null/0 = auto, >0 = manual)
    gain = doc_dict.get("analogue_gain")
    if gain is not None and float(gain) > 0:
        controls["AnalogueGain"] = float(gain)

    # AE exposure mode: "normal"=0, "short"=1, "long"=2, "custom"=3
    AE_MODE_MAP = {"normal": 0, "short": 1, "long": 2, "custom": 3}
    ae_mode = doc_dict.get("ae_exposure_mode")
    if ae_mode is not None:
        controls["AeExposureMode"] = AE_MODE_MAP.get(ae_mode, ae_mode) if isinstance(ae_mode, str) else int(ae_mode)

    # EV compensation
    ev = doc_dict.get("ev_compensation")
    if ev is not None:
        controls["ExposureValue"] = float(ev)

    # Image processing controls
    for firestore_key, picam2_key in [
        ("sharpness", "Sharpness"),
        ("contrast", "Contrast"),
        ("saturation", "Saturation"),
        ("brightness", "Brightness"),
    ]:
        val = doc_dict.get(firestore_key)
        if val is not None:
            controls[picam2_key] = float(val)

    # Noise reduction: "off"=0, "fast"=1, "high_quality"=2
    NR_MODE_MAP = {"off": 0, "fast": 1, "high_quality": 2}
    nr = doc_dict.get("noise_reduction")
    if nr is not None:
        controls["NoiseReductionMode"] = NR_MODE_MAP.get(nr, nr) if isinstance(nr, str) else int(nr)

    # AWB mode: "auto"=0, "incandescent"=1, "tungsten"=2, "fluorescent"=3, "indoor"=4, "daylight"=5, "cloudy"=6
    AWB_MODE_MAP = {"auto": 0, "incandescent": 1, "tungsten": 2, "fluorescent": 3, "indoor": 4, "daylight": 5, "cloudy": 6}
    awb = doc_dict.get("awb_mode")
    if awb is not None:
        controls["AwbMode"] = AWB_MODE_MAP.get(awb, awb) if isinstance(awb, str) else int(awb)

    out["camera_controls"] = controls

    return out


# ============================================================================
# DATA UPLOADER INTEGRATION
# ============================================================================

def run_uploader() -> None:
    """Execute data_uploader.py script to upload energy logs."""
    if not os.path.exists(config.DATA_UPLOADER_SCRIPT):
        logger.error(f"Data uploader not found: {config.DATA_UPLOADER_SCRIPT}")
        return

    try:
        # Run data uploader with current Python interpreter
        result = subprocess.run(
            [sys.executable, config.DATA_UPLOADER_SCRIPT],
            capture_output=True,
            text=True,
            check=False,
            timeout=60  # 1 minute timeout
        )

        if result.returncode == 0:
            logger.info("Energy data upload: SUCCESS")
        else:
            error_msg = result.stderr.strip() or result.stdout.strip()
            logger.error(f"Energy data upload FAILED (code {result.returncode}): {error_msg}")

    except subprocess.TimeoutExpired:
        logger.error("Energy data upload timed out after 60 seconds")
    except Exception as e:
        logger.error(f"Energy data upload exception: {e}")


def _upload_instance(meta: Dict[str, Any]) -> bool:
    """
    Upload all files for one motion capture instance and write a single
    grouped Firestore document.

    Args:
        meta: Parsed .meta.json dict with keys:
              instance_id, timestamp, motion_duration, capture_mode, files

    Returns:
        True if all files uploaded and Firestore write succeeded.
    """
    instance_id = meta.get("instance_id", "unknown")
    timestamp_str = meta.get("timestamp", config.get_timestamp_string())
    motion_duration = float(meta.get("motion_duration", 0.0))
    capture_mode = meta.get("capture_mode", "photo")
    file_basenames = meta.get("files", [])

    if not file_basenames:
        logger.warning(f"Instance {instance_id}: no files listed — skipping")
        return True  # No files, but sidecar can be removed

    local_cfg = load_local_config()
    mc_res = local_cfg.get("motion_capture_resolution", [4608, 2592])
    resolution_str = f"{mc_res[0]}x{mc_res[1]}"

    storage_paths = []
    image_urls = []
    uploaded_local_paths = []

    for basename in file_basenames:
        local_path = os.path.join(config.UPLOAD_QUEUE_DIR, basename)
        if not os.path.exists(local_path):
            logger.warning(f"  File missing: {basename} — skipping")
            continue

        storage_path = f"{config.SIGHTINGS_STORAGE_PATH}/{basename}"
        try:
            blob = storage_bucket.blob(storage_path)
            blob.upload_from_filename(local_path)
            blob.make_public()
            image_url = blob.public_url

            storage_paths.append(storage_path)
            image_urls.append(image_url)
            uploaded_local_paths.append(local_path)
            logger.info(f"  Uploaded: {basename}")

        except Exception as e:
            logger.error(f"  Failed to upload {basename}: {e}")
            traceback.print_exc()
            return False  # Partial upload — leave in queue for retry

    if not storage_paths:
        logger.error(f"Instance {instance_id}: all file uploads failed")
        return False

    # Write ONE Firestore doc using instance_id as document ID (idempotent)
    try:
        doc_ref = (
            db.collection("logs")
            .document("motion_captures")
            .collection("data")
            .document(instance_id)
        )
        doc_ref.set({
            "timestamp": timestamp_str,
            "motion_duration": motion_duration,
            "capture_mode": capture_mode,
            "file_count": len(storage_paths),
            "storage_paths": storage_paths,
            "image_urls": image_urls,
            "resolution": resolution_str,
            "is_identified": False,
            "species_name": "",
            "catalog_bird_id": "",
            "source_type": "motion_capture",
        })
        logger.info(f"Firestore doc written: {instance_id}")

    except Exception as e:
        logger.error(f"Firestore write failed for {instance_id}: {e}")
        traceback.print_exc()
        return False

    # Delete local files only after confirmed Firestore write
    for local_path in uploaded_local_paths:
        try:
            os.remove(local_path)
        except Exception as e:
            logger.warning(f"Could not delete {os.path.basename(local_path)}: {e}")

    return True


def _upload_legacy_queue(queue_contents: list) -> None:
    """
    Handle legacy bird_*.jpg files from the old motion_capture.py (no sidecar).
    Creates a single-image Firestore doc per file matching the old schema.
    This can be removed once pre-upgrade queued files are cleared.
    """
    legacy_files = sorted([
        f for f in queue_contents
        if f.endswith('.jpg') and f.startswith('bird_')
    ])

    if not legacy_files:
        return

    logger.info(f"Legacy queue: {len(legacy_files)} old-format file(s)")

    local_cfg = load_local_config()
    mc_res = local_cfg.get("motion_capture_resolution", [4608, 2592])
    resolution_str = f"{mc_res[0]}x{mc_res[1]}"

    for filename in legacy_files:
        filepath = os.path.join(config.UPLOAD_QUEUE_DIR, filename)
        try:
            file_size = os.path.getsize(filepath)
            storage_path = f"{config.SIGHTINGS_STORAGE_PATH}/{filename}"
            blob = storage_bucket.blob(storage_path)
            blob.upload_from_filename(filepath)
            blob.make_public()
            image_url = blob.public_url

            try:
                parts = filename.replace('.jpg', '').split('_')
                if len(parts) >= 3:
                    d, t = parts[1], parts[2]
                    ts_str = f"{d[:4]}-{d[4:6]}-{d[6:8]} {t[:2]}:{t[2:4]}:{t[4:6]}"
                else:
                    ts_str = config.get_timestamp_string()
            except Exception:
                ts_str = config.get_timestamp_string()

            db.collection("logs").document("motion_captures").collection("data").add({
                "imageUrl": image_url,
                "resolution": resolution_str,
                "sizeBytes": file_size,
                "storagePath": storage_path,
                "timestamp": ts_str,
                "isIdentified": False,
                "catalogBirdId": "",
                "speciesName": "",
                "source_type": "motion_capture_legacy",
            })

            os.remove(filepath)
            logger.info(f"Legacy upload: {filename}")

        except Exception as e:
            logger.error(f"Failed legacy upload {filename}: {e}")
            traceback.print_exc()


def batch_upload_queue() -> None:
    """
    Upload all queued motion capture instances to Firebase Storage and Firestore.

    New instance-based flow:
      1. Find all .meta.json sidecar files in upload_queue/
      2. For each instance: upload all referenced files, write one Firestore doc
      3. Delete sidecar on success; leave on failure (retry on next open)
      4. Fall back to legacy bird_*.jpg handling for pre-upgrade files
    """
    if not db or not storage_bucket:
        logger.warning("Batch upload skipped - Firebase not initialized")
        return

    if not os.path.exists(config.UPLOAD_QUEUE_DIR):
        logger.info("Upload queue directory does not exist - nothing to upload")
        return

    queue_contents = os.listdir(config.UPLOAD_QUEUE_DIR)

    # Find all instance sidecar files
    meta_files = sorted([
        f for f in queue_contents
        if f.endswith(config.INSTANCE_METADATA_SUFFIX)
    ])

    if not meta_files:
        logger.info("Upload queue: no pending motion instances")
        _upload_legacy_queue(queue_contents)
        return

    logger.info(f"=== BATCH UPLOAD: {len(meta_files)} instance(s) ===")
    success_count = 0
    fail_count = 0

    for meta_filename in meta_files:
        meta_path = os.path.join(config.UPLOAD_QUEUE_DIR, meta_filename)
        try:
            with open(meta_path, 'r') as f:
                meta = json.load(f)
        except Exception as e:
            logger.error(f"Could not read metadata {meta_filename}: {e}")
            fail_count += 1
            continue

        success = _upload_instance(meta)
        if success:
            try:
                os.remove(meta_path)
            except Exception as e:
                logger.warning(f"Could not delete sidecar {meta_filename}: {e}")
            success_count += 1
        else:
            fail_count += 1

    logger.info(f"=== BATCH UPLOAD DONE: {success_count} succeeded, {fail_count} failed ===")

    # Also handle any remaining legacy files
    _upload_legacy_queue(os.listdir(config.UPLOAD_QUEUE_DIR))


def on_batch_upload_snapshot(doc_snapshot, changes, read_time) -> None:
    """
    Callback when status/batch_upload_request document changes.
    Triggers a batch upload when requested == True from the app.
    """
    if not doc_snapshot:
        return

    try:
        doc_data = doc_snapshot[0].to_dict()
        if not doc_data:
            return

        if doc_data.get("requested", False):
            logger.info("Manual batch upload requested from app")
            # Clear the flag immediately to prevent double-triggering
            db.document(config.BATCH_UPLOAD_REQUEST_PATH).set({"requested": False})
            thread = threading.Thread(target=batch_upload_queue, daemon=True)
            thread.start()

    except Exception as e:
        logger.error(f"Batch upload listener error: {e}")
        traceback.print_exc()


def data_upload_loop() -> None:
    """
    Periodic data upload thread.
    Runs immediately on startup (energy + queued motion captures),
    then runs energy upload every DATA_UPLOAD_INTERVAL seconds.
    """
    logger.info("Data upload thread started - running initial upload")

    # Immediate upload on startup
    run_uploader()
    batch_upload_queue()

    # Periodic energy data upload loop
    while not data_upload_stop_flag.is_set():
        # Wait for interval (or until stop flag is set)
        data_upload_stop_flag.wait(config.DATA_UPLOAD_INTERVAL)

        if data_upload_stop_flag.is_set():
            break

        logger.info(f"Running periodic upload (interval: {config.DATA_UPLOAD_INTERVAL}s)")
        run_uploader()

    logger.info("Data upload thread stopped")


# ============================================================================
# FIREBASE INITIALIZATION
# ============================================================================

def init_firebase() -> bool:
    """
    Initialize Firebase Admin SDK with Firestore and Storage.

    Returns:
        True if successful, False otherwise
    """
    global db, storage_bucket

    try:
        db, storage_bucket = config.init_firebase(
            app_name='system_updater_app',
            require_firestore=True,
            require_storage=True
        )
        logger.info("Firebase initialized successfully (Firestore + Storage)")
        return True

    except Exception as e:
        logger.error(f"Firebase initialization failed: {e}")
        traceback.print_exc()
        return False


# ============================================================================
# FIRESTORE LISTENER
# ============================================================================

def on_settings_snapshot(doc_snapshot, changes, read_time) -> None:
    """
    Callback when config/settings document changes.

    Args:
        doc_snapshot: Firestore document snapshot
        changes: List of changes
        read_time: Timestamp of read
    """
    if not doc_snapshot:
        return

    try:
        logger.info("*** Settings update received ***")
        doc_data = doc_snapshot[0].to_dict()

        if doc_data:
            logger.info(f"Raw data: {json.dumps(doc_data)}")

            # Normalize settings
            normalized = normalize_settings(doc_data)

            if normalized:
                # Merge with existing settings
                base = load_local_config()
                base.update(normalized)
                save_local_config(base)
            else:
                logger.warning("Received settings could not be normalized - ignoring")

    except Exception as e:
        logger.error(f"Listener error: {e}")
        traceback.print_exc()


# ============================================================================
# TEST CAPTURE
# ============================================================================

def load_camera_settings():
    """
    Load camera resolution and controls from local config file.
    Mirrors the logic in motion_capture.py.

    Returns:
        Tuple of (resolution_tuple, controls_dict)
    """
    resolution = config.DEFAULT_CAPTURE_RESOLUTION
    controls = dict(config.DEFAULT_CAMERA_CONTROLS)

    try:
        if os.path.exists(config.LOCAL_CONFIG_FILE):
            with open(config.LOCAL_CONFIG_FILE, 'r') as f:
                local_config = json.load(f)

            # Resolution
            res = local_config.get("motion_capture_resolution")
            if isinstance(res, (list, tuple)) and len(res) >= 2:
                resolution = (int(res[0]), int(res[1]))

            # Camera controls
            saved_controls = local_config.get("camera_controls", {})
            if saved_controls:
                controls.update(saved_controls)

    except Exception as e:
        logger.warning(f"Could not load camera settings, using defaults: {e}")

    return resolution, controls


def cleanup_old_test_captures():
    """Delete old test captures from Storage and Firestore, keeping the most recent ones."""
    try:
        from firebase_admin import firestore as firestore_module
        history_ref = db.collection("logs").document("test_captures").collection("history")
        docs = list(history_ref.order_by("timestamp", direction=firestore_module.Query.DESCENDING).stream())

        if len(docs) <= config.MAX_TEST_CAPTURES:
            return

        old_docs = docs[config.MAX_TEST_CAPTURES:]
        for doc in old_docs:
            data = doc.to_dict()
            # Delete from Storage
            storage_path = data.get("storagePath")
            if storage_path and storage_bucket:
                try:
                    blob = storage_bucket.blob(storage_path)
                    blob.delete()
                    logger.info(f"Deleted old test capture from storage: {storage_path}")
                except Exception as e:
                    logger.warning(f"Could not delete storage blob {storage_path}: {e}")
            # Delete Firestore doc
            doc.reference.delete()

        logger.info(f"Cleaned up {len(old_docs)} old test capture(s)")

    except Exception as e:
        logger.warning(f"Test capture cleanup failed: {e}")


def take_test_capture():
    """
    Take a single test photo using current camera settings and upload it.
    Runs in a background thread to avoid blocking the Firestore listener.
    """
    global is_test_capturing

    if is_test_capturing:
        logger.warning("Test capture already in progress - ignoring")
        return

    is_test_capturing = True
    logger.info("=== TEST CAPTURE REQUESTED ===")

    picam2 = None
    filepath = None

    try:
        # Lazy import — Picamera2 only available on the Pi
        from picamera2 import Picamera2

        # 1. Load current camera settings
        resolution, controls = load_camera_settings()
        logger.info(f"Test capture settings: {resolution}, controls: {controls}")

        # 2. Initialize camera
        picam2 = Picamera2()
        camera_config = picam2.create_still_configuration(
            main={"size": resolution}
        )
        picam2.configure(camera_config)

        # 3. Start camera and apply controls
        picam2.start()
        try:
            picam2.set_controls(controls)
            logger.info("Camera controls applied")
        except Exception as e:
            logger.warning(f"Some camera controls failed to apply: {e}")

        # 4. Wait for warmup
        logger.info(f"Warming up camera for {config.CAMERA_WARMUP_TIME}s")
        time.sleep(config.CAMERA_WARMUP_TIME)

        # 5. Capture photo
        timestamp = config.get_timestamp_string()
        filename = config.get_timestamp_filename(prefix="test", extension="jpg")
        config.ensure_directory_exists(config.UPLOAD_QUEUE_DIR)
        filepath = os.path.join(config.UPLOAD_QUEUE_DIR, filename)
        picam2.capture_file(filepath)
        logger.info(f"Test photo captured: {filepath}")

        # 6. Stop camera immediately (power saving)
        picam2.stop()
        picam2.close()
        picam2 = None

        # 7. Upload to Firebase Storage
        file_size = os.path.getsize(filepath)
        storage_path = f"{config.TEST_CAPTURES_STORAGE_PATH}/{filename}"
        blob = storage_bucket.blob(storage_path)
        blob.upload_from_filename(filepath)
        blob.make_public()
        image_url = blob.public_url
        logger.info(f"Uploaded to {storage_path}")

        # 8. Log to history collection
        resolution_str = f"{resolution[0]}x{resolution[1]}"
        db.collection("logs").document("test_captures").collection("history").add({
            "imageUrl": image_url,
            "resolution": resolution_str,
            "sizeBytes": file_size,
            "storagePath": storage_path,
            "timestamp": timestamp,
        })

        # 9. Update status document with result
        db.document(config.TEST_CAPTURE_STATUS_PATH).set({
            "requested": False,
            "imageUrl": image_url,
            "resolution": resolution_str,
            "timestamp": timestamp,
        })
        logger.info("Test capture result written to Firestore")

        # 10. Clean up local file
        os.remove(filepath)
        filepath = None

        # 11. Clean up old captures
        cleanup_old_test_captures()

        logger.info("=== TEST CAPTURE COMPLETE ===")

    except Exception as e:
        logger.error(f"Test capture failed: {e}")
        traceback.print_exc()
        # Write error back so the app knows it failed
        try:
            db.document(config.TEST_CAPTURE_STATUS_PATH).set({
                "requested": False,
                "error": str(e),
                "timestamp": config.get_timestamp_string(),
            })
        except Exception:
            pass

    finally:
        # Ensure camera is stopped
        if picam2:
            try:
                picam2.stop()
                picam2.close()
            except Exception:
                pass
        # Clean up temp file if still present
        if filepath and os.path.exists(filepath):
            try:
                os.remove(filepath)
            except Exception:
                pass
        is_test_capturing = False


def on_test_capture_snapshot(doc_snapshot, changes, read_time) -> None:
    """
    Callback when status/test_capture document changes.
    Triggers a test capture when requested == True.
    """
    if not doc_snapshot:
        return

    try:
        doc_data = doc_snapshot[0].to_dict()
        if not doc_data:
            return

        if doc_data.get("requested", False):
            logger.info("Test capture request detected")
            # Run in a thread to avoid blocking the listener
            thread = threading.Thread(target=take_test_capture, daemon=True)
            thread.start()

    except Exception as e:
        logger.error(f"Test capture listener error: {e}")
        traceback.print_exc()


# ============================================================================
# SIGNAL HANDLING
# ============================================================================

def signal_handler(sig, frame) -> None:
    """Handle shutdown signals gracefully."""
    logger.info("Shutdown signal received")
    data_upload_stop_flag.set()
    main_thread_event.set()


# ============================================================================
# MAIN EXECUTION
# ============================================================================

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Initialize Firebase
    if not init_firebase():
        logger.error("Exiting due to Firebase initialization failure")
        sys.exit(1)

    # Start data upload thread
    upload_thread = threading.Thread(target=data_upload_loop, daemon=True)
    upload_thread.start()
    logger.info(f"Data upload thread started (interval: {config.DATA_UPLOAD_INTERVAL}s)")

    # Load and save initial config
    logger.info("Loading initial configuration")
    initial_config = load_local_config()
    save_local_config(initial_config)

    # Setup Firestore listeners
    logger.info(f"Attaching listener to: {config.CONFIG_SETTINGS_PATH}")
    doc_ref = db.document(config.CONFIG_SETTINGS_PATH)
    unsubscribe_func = doc_ref.on_snapshot(on_settings_snapshot)

    logger.info(f"Attaching listener to: {config.TEST_CAPTURE_STATUS_PATH}")
    test_capture_ref = db.document(config.TEST_CAPTURE_STATUS_PATH)
    unsubscribe_test_capture = test_capture_ref.on_snapshot(on_test_capture_snapshot)

    logger.info(f"Attaching listener to: {config.BATCH_UPLOAD_REQUEST_PATH}")
    batch_upload_ref = db.document(config.BATCH_UPLOAD_REQUEST_PATH)
    unsubscribe_batch_upload = batch_upload_ref.on_snapshot(on_batch_upload_snapshot)

    logger.info("System updater active - listening for config changes, test captures, and batch upload requests")
    logger.info("-" * 60)

    try:
        # Block until shutdown signal received
        main_thread_event.wait()

    except Exception as e:
        logger.error(f"Error in main loop: {e}")
        traceback.print_exc()

    finally:
        # Clean shutdown
        for unsub in [unsubscribe_func, unsubscribe_test_capture, unsubscribe_batch_upload]:
            if unsub:
                try:
                    unsub.unsubscribe()
                except Exception:
                    pass

        logger.info("System updater shutdown complete")
        sys.exit(0)
