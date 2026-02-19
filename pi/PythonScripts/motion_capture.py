# -*- coding: utf-8 -*-
"""
MOTION CAPTURE SCRIPT

PIR-triggered capture with post-motion duration filtering.

New capture flow:
  1. PIR triggers → immediately enter capture mode (no waiting)
  2. Track how long motion is sustained
  3. In capture mode, take photos at interval OR record video
  4. When PIR drops → end capture session
  5. Post-filter: if motion lasted < threshold → discard entire session
  6. If long enough → write sidecar .meta.json for batch upload

Power optimization: Camera is powered off when idle.
"""

import os
import time
import sys
import json
import signal
import traceback
import threading
from datetime import datetime

import shared_config as config

try:
    from picamera2 import Picamera2
    from gpiozero import MotionSensor
except ImportError as e:
    print(f"FATAL: Hardware libraries not found: {e}")
    print("Install with: pip install picamera2 gpiozero")
    sys.exit(1)

logger = config.setup_logging("motion_capture")

# ============================================================================
# GLOBAL STATE
# ============================================================================

picam2 = None
db = None
storage_bucket = None

# State machine: 'idle' | 'capturing'
_state = 'idle'
_state_lock = threading.Lock()

_capture_thread = None
_motion_start_time = None
_motion_end_time = None
_motion_still_active = False  # Updated by PIR callbacks during capture


# ============================================================================
# SETTINGS LOADERS
# ============================================================================

def load_camera_settings():
    """
    Load camera resolution and controls from local config file.
    Falls back to shared_config defaults if file is missing or invalid.

    Returns:
        tuple: (resolution, controls_dict)
    """
    resolution = config.DEFAULT_CAPTURE_RESOLUTION
    controls = dict(config.DEFAULT_CAMERA_CONTROLS)

    if os.path.exists(config.LOCAL_CONFIG_FILE):
        try:
            with open(config.LOCAL_CONFIG_FILE, 'r') as f:
                settings = json.load(f)

            res = settings.get("motion_capture_resolution")
            if isinstance(res, (list, tuple)) and len(res) >= 2:
                resolution = (int(res[0]), int(res[1]))

            saved_controls = settings.get("camera_controls")
            if isinstance(saved_controls, dict):
                controls.update(saved_controls)

        except Exception as e:
            logger.warning(f"Could not load camera settings, using defaults: {e}")

    return resolution, controls


def load_motion_settings():
    """
    Load all motion capture settings from local config file.
    Falls back to shared_config defaults for any missing key.

    Returns:
        dict with keys:
            motion_threshold_seconds  (float) — post-capture discard filter
            capture_mode              (str)   — 'photo' | 'video'
            photo_capture_interval    (float) — seconds between photos
            video_duration_mode       (str)   — 'fixed' | 'motion'
            video_fixed_duration      (float) — seconds for fixed video
    """
    settings = {
        "motion_threshold_seconds": config.MIN_PULSE_DURATION,
        "capture_mode": config.DEFAULT_CAPTURE_MODE,
        "photo_capture_interval": config.DEFAULT_PHOTO_INTERVAL,
        "video_duration_mode": config.DEFAULT_VIDEO_DURATION_MODE,
        "video_fixed_duration": config.DEFAULT_VIDEO_FIXED_DURATION,
    }

    if os.path.exists(config.LOCAL_CONFIG_FILE):
        try:
            with open(config.LOCAL_CONFIG_FILE, 'r') as f:
                local = json.load(f)

            threshold = local.get("motion_threshold_seconds")
            if isinstance(threshold, (int, float)) and threshold >= 1.0:
                settings["motion_threshold_seconds"] = float(threshold)

            capture_mode = local.get("capture_mode")
            if capture_mode in ('photo', 'video'):
                settings["capture_mode"] = capture_mode

            photo_interval = local.get("photo_capture_interval")
            if isinstance(photo_interval, (int, float)) and photo_interval >= 0.5:
                settings["photo_capture_interval"] = float(photo_interval)

            video_duration_mode = local.get("video_duration_mode")
            if video_duration_mode in ('fixed', 'motion'):
                settings["video_duration_mode"] = video_duration_mode

            video_fixed_duration = local.get("video_fixed_duration")
            if isinstance(video_fixed_duration, (int, float)) and video_fixed_duration >= 1.0:
                settings["video_fixed_duration"] = float(video_fixed_duration)

        except Exception as e:
            logger.warning(f"Could not load motion settings, using defaults: {e}")

    return settings


# ============================================================================
# CAMERA CONFIGURATION
# ============================================================================

def _reconfigure_camera(resolution, capture_mode):
    """
    Configure picam2 for the correct mode.
    Must be called before picam2.start() each session since mode may change.
    """
    global picam2

    if capture_mode == 'video':
        cam_config = picam2.create_video_configuration(
            main={"size": resolution}
        )
        logger.info(f"Camera configured for video at {resolution}")
    else:
        cam_config = picam2.create_still_configuration(
            main={"size": resolution}
        )
        logger.info(f"Camera configured for still capture at {resolution}")

    picam2.configure(cam_config)


# ============================================================================
# CAPTURE WORKERS
# ============================================================================

def _run_photo_loop(motion_settings, instance_id):
    """
    Take photos at photo_capture_interval while PIR is active.

    Returns:
        list[str]: Local filepaths of captured photos
    """
    interval = motion_settings["photo_capture_interval"]
    files = []
    photo_index = 0

    while _motion_still_active:
        filename = f"{instance_id}_p{photo_index:02d}.jpg"
        filepath = os.path.join(config.UPLOAD_QUEUE_DIR, filename)

        picam2.capture_file(filepath)
        files.append(filepath)
        logger.info(f"Photo {photo_index + 1}: {filename}")
        photo_index += 1

        # Wait for interval, but check PIR state every 0.5s so we exit promptly
        elapsed = 0.0
        while _motion_still_active and elapsed < interval:
            time.sleep(0.5)
            elapsed += 0.5

    return files


def _run_video_capture(motion_settings, instance_id):
    """
    Record a single video file.

    video_duration_mode == 'fixed': record for video_fixed_duration seconds
    video_duration_mode == 'motion': record until PIR drops

    Returns:
        list[str]: List with one filepath, or empty list on failure
    """
    try:
        from picamera2.encoders import H264Encoder
        from picamera2.outputs import FileOutput
    except ImportError:
        logger.error("H264Encoder not available — cannot record video")
        return []

    duration_mode = motion_settings["video_duration_mode"]
    fixed_duration = motion_settings["video_fixed_duration"]

    filename = f"{instance_id}_v00.h264"
    filepath = os.path.join(config.UPLOAD_QUEUE_DIR, filename)

    encoder = H264Encoder()
    try:
        picam2.start_recording(encoder, filepath)
        logger.info(f"Video recording started: {filename}")

        if duration_mode == 'fixed':
            time.sleep(fixed_duration)
        else:
            # Poll PIR state; exit when motion ends
            while _motion_still_active:
                time.sleep(0.25)

        picam2.stop_recording()
        logger.info(f"Video recording complete: {filename}")
        return [filepath]

    except Exception as e:
        logger.error(f"Video recording failed: {e}")
        traceback.print_exc()
        try:
            picam2.stop_recording()
        except Exception:
            pass
        return []


# ============================================================================
# INSTANCE MANAGEMENT
# ============================================================================

def _write_instance_metadata(instance_id, session_timestamp, motion_duration,
                              capture_mode, captured_files):
    """
    Write a sidecar .meta.json file to upload_queue/ that groups the files
    from this motion instance. system_updater reads these to create
    grouped Firestore documents.

    Args:
        instance_id:       str   — "inst_YYYYMMDD_HHMMSS"
        session_timestamp: datetime — start of motion
        motion_duration:   float — seconds PIR was active
        capture_mode:      str   — 'photo' | 'video'
        captured_files:    list  — local filepaths captured this session
    """
    meta_filename = f"{instance_id}{config.INSTANCE_METADATA_SUFFIX}"
    meta_filepath = os.path.join(config.UPLOAD_QUEUE_DIR, meta_filename)

    file_basenames = [os.path.basename(f) for f in captured_files]

    metadata = {
        "instance_id": instance_id,
        "timestamp": session_timestamp.strftime("%Y-%m-%d %H:%M:%S"),
        "motion_duration": round(motion_duration, 2),
        "capture_mode": capture_mode,
        "files": file_basenames,
    }

    with open(meta_filepath, 'w') as f:
        json.dump(metadata, f, indent=2)

    logger.info(f"Instance metadata written: {meta_filename}")


def _discard_files(filepaths):
    """Delete captured files from a session that was too short to keep."""
    for fp in filepaths:
        try:
            os.remove(fp)
            logger.info(f"Discarded: {os.path.basename(fp)}")
        except Exception as e:
            logger.warning(f"Could not discard {fp}: {e}")


# ============================================================================
# CAPTURE SESSION WORKER
# ============================================================================

def _capture_session_worker():
    """
    Runs in a background thread during a capture session.

    Lifecycle:
      1. Load all settings
      2. Configure and start camera
      3. Run photo loop or video recording while PIR is active
      4. After PIR drops: compute motion duration
      5. If duration < threshold: discard all files
      6. Else: write sidecar metadata for batch upload
      7. Stop camera, reset state to 'idle'
    """
    global _state, _motion_end_time

    motion_settings = load_motion_settings()
    camera_resolution, camera_controls = load_camera_settings()

    capture_mode = motion_settings["capture_mode"]
    threshold = motion_settings["motion_threshold_seconds"]

    session_timestamp = datetime.now()
    session_start = time.monotonic()
    instance_id = "inst_" + session_timestamp.strftime("%Y%m%d_%H%M%S")

    captured_files = []

    try:
        _reconfigure_camera(camera_resolution, capture_mode)
        picam2.start()

        try:
            picam2.set_controls(camera_controls)
        except Exception as e:
            logger.warning(f"Some camera controls failed: {e}")

        logger.info(f"Camera started, warming up {config.CAMERA_WARMUP_TIME}s")
        time.sleep(config.CAMERA_WARMUP_TIME)

        if capture_mode == 'photo':
            captured_files = _run_photo_loop(motion_settings, instance_id)
        else:
            captured_files = _run_video_capture(motion_settings, instance_id)

    except Exception as e:
        logger.error(f"Capture session error: {e}")
        traceback.print_exc()

    finally:
        try:
            picam2.stop()
            logger.info("Camera stopped")
        except Exception as e:
            logger.warning(f"Could not stop camera: {e}")

    # Determine actual motion duration
    end_time = _motion_end_time if _motion_end_time is not None else time.monotonic()
    motion_duration = end_time - session_start

    logger.info(f"Motion duration: {motion_duration:.1f}s (threshold: {threshold}s)")

    if motion_duration < threshold:
        logger.info(
            f"Duration below threshold — discarding {len(captured_files)} file(s)"
        )
        _discard_files(captured_files)
    elif captured_files:
        logger.info(
            f"Queuing {len(captured_files)} file(s) for batch upload"
        )
        try:
            _write_instance_metadata(
                instance_id=instance_id,
                session_timestamp=session_timestamp,
                motion_duration=motion_duration,
                capture_mode=capture_mode,
                captured_files=captured_files,
            )
        except Exception as e:
            logger.error(f"Could not write instance metadata: {e}")
    else:
        logger.warning("No files captured this session")

    with _state_lock:
        _state = 'idle'

    logger.info("=== Capture session complete — idle ===\n")


# ============================================================================
# PIR SENSOR CALLBACKS
# ============================================================================

def motion_started():
    """
    PIR went high — begin capture immediately if not already capturing.
    If already in a session (re-trigger during interval wait), just ensure
    _motion_still_active stays True so the photo loop continues.
    """
    global _state, _capture_thread, _motion_start_time, _motion_end_time
    global _motion_still_active

    _motion_still_active = True
    _motion_end_time = None  # Reset end time on re-trigger

    with _state_lock:
        if _state == 'capturing':
            logger.debug("PIR re-triggered during active session")
            return

        _state = 'capturing'

    _motion_start_time = time.monotonic()
    logger.info("=== MOTION DETECTED — CAPTURE SESSION STARTED ===")

    _capture_thread = threading.Thread(
        target=_capture_session_worker,
        daemon=True,
        name="capture_worker"
    )
    _capture_thread.start()


def motion_ended():
    """PIR went low — signal worker thread to wrap up."""
    global _motion_still_active, _motion_end_time

    _motion_still_active = False
    _motion_end_time = time.monotonic()
    logger.info("PIR dropped — motion ended")


# ============================================================================
# FIREBASE + CAMERA INIT
# ============================================================================

def init_firebase():
    """Initialize Firebase Admin SDK."""
    global db, storage_bucket
    try:
        db, storage_bucket = config.init_firebase(
            app_name='motion_capture_app',
            require_firestore=True,
            require_storage=True
        )
        logger.info("Firebase initialized successfully")
        return True
    except Exception as e:
        logger.error(f"Firebase initialization failed: {e}")
        traceback.print_exc()
        return False


def init_camera():
    """
    Verify camera hardware is available.
    Actual configuration is deferred to each capture session
    (since mode may differ between photo/video).
    """
    global picam2
    try:
        picam2 = Picamera2()
        logger.info("Camera hardware verified")
        return True
    except Exception as e:
        logger.error(f"Camera not available: {e}")
        traceback.print_exc()
        return False


# ============================================================================
# CLEANUP AND SIGNAL HANDLING
# ============================================================================

def cleanup():
    """Clean up resources on shutdown."""
    global _capture_thread, picam2

    logger.info("Shutting down...")

    # Signal any active capture session to stop
    global _motion_still_active
    _motion_still_active = False

    # Wait briefly for the worker thread to finish
    if _capture_thread and _capture_thread.is_alive():
        logger.info("Waiting for capture session to finish...")
        _capture_thread.join(timeout=5.0)

    # Stop camera if running
    if picam2:
        try:
            picam2.stop()
        except Exception:
            pass

    logger.info("Cleanup complete")


def signal_handler(sig, frame):
    """Handle shutdown signals gracefully."""
    cleanup()
    sys.exit(0)


# ============================================================================
# MAIN
# ============================================================================

if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        config.ensure_directory_exists(config.UPLOAD_QUEUE_DIR)

        if not init_firebase():
            logger.error("Exiting due to Firebase initialization failure")
            sys.exit(1)

        if not init_camera():
            logger.error("Exiting due to camera initialization failure")
            sys.exit(1)

        pir = MotionSensor(config.MOTION_PIN, threshold=config.DEBOUNCE_DELAY)
        pir.when_motion = motion_started
        pir.when_no_motion = motion_ended

        initial_settings = load_motion_settings()
        logger.info(f"Motion detection active on GPIO pin {config.MOTION_PIN}")
        logger.info(f"Duration filter threshold: {initial_settings['motion_threshold_seconds']}s")
        logger.info(f"Capture mode: {initial_settings['capture_mode']}")
        logger.info("Camera is OFF (low-power mode). Waiting for motion...")
        logger.info("-" * 60)

        signal.pause()

    except Exception as e:
        logger.error(f"Fatal error: {e}")
        traceback.print_exc()
    finally:
        cleanup()
