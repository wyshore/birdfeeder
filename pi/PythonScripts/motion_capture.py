# -*- coding: utf-8 -*-
"""
MOTION CAPTURE SCRIPT

PIR-triggered photo capture with sustained motion filtering.
Captures high-resolution photos when motion is detected for MIN_PULSE_DURATION
seconds, then uploads to Firebase Storage and logs metadata to Firestore.

Power optimization: Camera sensor is powered off when idle.
"""

import os
import time
import sys
import signal
import json
import traceback
import threading
from datetime import datetime

# Import shared configuration
import shared_config as config

# Hardware library imports
try:
    from picamera2 import Picamera2
    from gpiozero import MotionSensor
except ImportError as e:
    print(f"FATAL: Hardware libraries not found: {e}")
    print("Install with: pip install picamera2 gpiozero")
    sys.exit(1)

# Setup logging
logger = config.setup_logging("motion_capture")

# Global state
picam2 = None
db = None
storage_bucket = None
is_capturing = False
delayed_capture_timer = None
current_resolution = None  # Track configured resolution to detect changes


def load_camera_settings():
    """
    Load camera controls and resolution from local config file.
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

            # Resolution from local config
            res = settings.get("motion_capture_resolution")
            if isinstance(res, (list, tuple)) and len(res) >= 2:
                resolution = (int(res[0]), int(res[1]))

            # Camera controls from local config (merge over defaults)
            saved_controls = settings.get("camera_controls")
            if isinstance(saved_controls, dict):
                controls.update(saved_controls)

        except Exception as e:
            logger.warning(f"Could not load local config, using defaults: {e}")

    return resolution, controls


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
    """Configure Picamera2 with settings from local config (does not start sensor)."""
    global picam2, current_resolution
    try:
        resolution, _ = load_camera_settings()
        picam2 = Picamera2()
        camera_config = picam2.create_still_configuration(
            main={"size": resolution}
        )
        picam2.configure(camera_config)
        current_resolution = resolution
        logger.info(f"Camera configured at {resolution}")
        return True
    except Exception as e:
        logger.error(f"Camera initialization failed: {e}")
        traceback.print_exc()
        return False


def upload_photo(filepath, filename, timestamp):
    """
    Upload photo to Firebase Storage and log metadata to Firestore.

    Args:
        filepath: Local path to photo file
        filename: Name for the uploaded file
        timestamp: Timestamp string for metadata

    Returns:
        bool: True if successful, False otherwise
    """
    if not db or not storage_bucket:
        logger.warning("Skipping upload - Firebase not initialized")
        return False

    try:
        # Get file size
        file_size = os.path.getsize(filepath)
        logger.info(f"Uploading {filename} ({file_size / 1024 / 1024:.2f} MB)")

        # Upload to Storage
        storage_path = f"{config.SIGHTINGS_STORAGE_PATH}/{filename}"
        blob = storage_bucket.blob(storage_path)
        blob.upload_from_filename(filepath)
        blob.make_public()
        image_url = blob.public_url
        logger.info(f"Uploaded to {storage_path}")

        # Log metadata to Firestore
        db.collection("logs").document("motion_captures").collection("data").add({
            "imageUrl": image_url,
            "resolution": f"{current_resolution[0]}x{current_resolution[1]}",
            "sizeBytes": file_size,
            "storagePath": storage_path,
            "timestamp": timestamp,
            "isIdentified": False,
            "catalogBirdId": "",
            "speciesName": "",
        })
        logger.info("Metadata logged to Firestore")

        # Clean up local file
        os.remove(filepath)
        logger.info("Local file cleaned up")
        return True

    except Exception as e:
        logger.error(f"Upload failed: {e}")
        traceback.print_exc()
        # Move failed file back to queue for later retry
        try:
            os.rename(filepath, os.path.join(config.UPLOAD_QUEUE_DIR, filename))
            logger.info("File moved to upload queue for retry")
        except Exception:
            pass
        return False


def capture_sequence():
    """
    Execute photo capture, upload, and logging sequence.
    Called by timer thread after MIN_PULSE_DURATION seconds of sustained motion.
    """
    global is_capturing, delayed_capture_timer, current_resolution

    if is_capturing:
        logger.warning("Timer expired but camera busy - skipping capture")
        return

    is_capturing = True
    logger.info("=== SUSTAINED MOTION CONFIRMED - CAPTURING ===")

    try:
        # Reload settings (may have changed via app since last capture)
        resolution, controls = load_camera_settings()

        # Reconfigure camera if resolution changed
        if current_resolution is None or resolution != current_resolution:
            if current_resolution is not None:
                logger.info(f"Resolution changed: {current_resolution} -> {resolution}")
            camera_config = picam2.create_still_configuration(
                main={"size": resolution}
            )
            picam2.configure(camera_config)
            current_resolution = resolution

        # Start camera sensor
        picam2.start()

        # Apply camera controls
        try:
            picam2.set_controls(controls)
            logger.info(f"Camera controls applied: {controls}")
        except Exception as e:
            logger.warning(f"Some camera controls failed to apply: {e}")

        logger.info(f"Camera started, warming up for {config.CAMERA_WARMUP_TIME}s")
        time.sleep(config.CAMERA_WARMUP_TIME)

        # Generate filename and path
        timestamp = config.get_timestamp_string()
        filename = config.get_timestamp_filename(prefix="bird", extension="jpg")
        filepath = os.path.join(config.UPLOAD_QUEUE_DIR, filename)

        # Capture photo
        picam2.capture_file(filepath)
        logger.info(f"Photo captured: {filepath}")

        # Upload and log
        upload_photo(filepath, filename, timestamp)

    except Exception as e:
        logger.error(f"Capture sequence failed: {e}")
        traceback.print_exc()

    finally:
        # Stop camera sensor (power saving)
        try:
            picam2.stop()
            logger.info("Camera stopped")
        except Exception as e:
            logger.warning(f"Could not stop camera: {e}")

        is_capturing = False
        logger.info("=== Capture complete, waiting for motion ===\n")


def motion_started():
    """
    PIR motion detected - start timer for sustained motion check.
    Called by gpiozero when motion sensor triggers.
    """
    global delayed_capture_timer, is_capturing

    if is_capturing:
        logger.debug("Motion detected but capture in progress - ignoring")
        return

    # Cancel existing timer if motion re-detected
    if delayed_capture_timer and delayed_capture_timer.is_alive():
        delayed_capture_timer.cancel()
        logger.info(f"Motion re-detected, restarting {config.MIN_PULSE_DURATION}s timer")

    # Start new timer
    delayed_capture_timer = threading.Timer(config.MIN_PULSE_DURATION, capture_sequence)
    delayed_capture_timer.daemon = True
    delayed_capture_timer.start()

    logger.info(f"Motion detected - {config.MIN_PULSE_DURATION}s timer started")


def motion_ended():
    """
    PIR motion stopped - cancel timer if motion was too brief.
    Called by gpiozero when motion sensor deactivates.
    """
    global delayed_capture_timer

    if delayed_capture_timer and delayed_capture_timer.is_alive():
        delayed_capture_timer.cancel()
        logger.info("Motion stopped early - timer cancelled (false positive filtered)")

    delayed_capture_timer = None


def cleanup():
    """Clean up resources on shutdown."""
    global delayed_capture_timer, picam2

    logger.info("Shutting down...")

    # Cancel any pending timer
    if delayed_capture_timer and delayed_capture_timer.is_alive():
        delayed_capture_timer.cancel()

    # Stop camera if running
    if picam2:
        try:
            if picam2.started:
                picam2.stop()
        except Exception:
            pass

    logger.info("Cleanup complete")


def signal_handler(sig, frame):
    """Handle shutdown signals gracefully."""
    cleanup()
    sys.exit(0)


if __name__ == "__main__":
    # Setup signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        # Ensure upload queue directory exists
        config.ensure_directory_exists(config.UPLOAD_QUEUE_DIR)

        # Initialize Firebase
        if not init_firebase():
            logger.error("Exiting due to Firebase initialization failure")
            sys.exit(1)

        # Initialize camera
        if not init_camera():
            logger.error("Exiting due to camera initialization failure")
            sys.exit(1)

        # Initialize PIR motion sensor
        pir = MotionSensor(config.MOTION_PIN, threshold=config.DEBOUNCE_DELAY)
        pir.when_motion = motion_started
        pir.when_no_motion = motion_ended

        logger.info(f"Motion detection active on GPIO pin {config.MOTION_PIN}")
        logger.info(f"Sustained motion filter: {config.MIN_PULSE_DURATION}s")
        logger.info("Camera is OFF (low-power mode). Press CTRL+C to exit")
        logger.info("-" * 60)

        # Keep script running and wait for motion events
        signal.pause()

    except Exception as e:
        logger.error(f"Fatal error: {e}")
        traceback.print_exc()
    finally:
        cleanup()
