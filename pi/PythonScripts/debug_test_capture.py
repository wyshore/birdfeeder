# -*- coding: utf-8 -*-
"""
DEBUG TEST CAPTURE - Manual test script

Run this to manually trigger a test capture and see full error output.
Usage: python3 debug_test_capture.py
"""

import sys
import traceback
import json
import os
import time

# Import shared config
import shared_config as config

# Setup logging
logger = config.setup_logging("debug_test_capture")

# Firebase and Camera imports
try:
    from firebase_admin import firestore
    from picamera2 import Picamera2
except ImportError as e:
    logger.error(f"FATAL: Required library not found: {e}")
    sys.exit(1)


def load_camera_settings():
    """Load current camera settings from local config."""
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
        logger.warning(f"Could not load camera settings: {e}")

    return resolution, controls


def init_firebase():
    """Initialize Firebase."""
    try:
        db, storage_bucket = config.init_firebase(
            app_name='debug_test_capture_app',
            require_firestore=True,
            require_storage=True
        )
        logger.info("Firebase initialized")
        return db, storage_bucket
    except Exception as e:
        logger.error(f"Firebase initialization failed: {e}")
        traceback.print_exc()
        raise


def take_test_capture():
    """Take a single test photo and upload it."""
    logger.info("=== MANUAL TEST CAPTURE STARTED ===")

    picam2 = None
    filepath = None

    try:
        # Initialize Firebase
        logger.info("Initializing Firebase...")
        db, storage_bucket = init_firebase()

        # Load settings
        logger.info("Loading camera settings...")
        resolution, controls = load_camera_settings()
        logger.info(f"Settings loaded: resolution={resolution}, controls={controls}")

        # Initialize camera
        logger.info("Initializing camera...")
        picam2 = Picamera2()
        camera_config = picam2.create_still_configuration(
            main={"size": resolution}
        )
        picam2.configure(camera_config)
        logger.info(f"Camera configured at {resolution}")

        # Start camera
        logger.info("Starting camera...")
        picam2.start()

        # Apply controls
        try:
            picam2.set_controls(controls)
            logger.info("Camera controls applied")
        except Exception as e:
            logger.warning(f"Some camera controls failed: {e}")

        # Warmup
        logger.info(f"Warming up for {config.CAMERA_WARMUP_TIME}s...")
        time.sleep(config.CAMERA_WARMUP_TIME)

        # Capture
        logger.info("Capturing photo...")
        timestamp = config.get_timestamp_string()
        filename = config.get_timestamp_filename(prefix="test", extension="jpg")
        config.ensure_directory_exists(config.UPLOAD_QUEUE_DIR)
        filepath = os.path.join(config.UPLOAD_QUEUE_DIR, filename)
        
        picam2.capture_file(filepath)
        logger.info(f"Photo captured: {filepath}")

        # Upload
        logger.info("Uploading to Firebase Storage...")
        file_size = os.path.getsize(filepath)
        storage_path = f"{config.TEST_CAPTURES_STORAGE_PATH}/{filename}"
        blob = storage_bucket.blob(storage_path)
        blob.upload_from_filename(filepath)
        blob.make_public()
        image_url = blob.public_url
        logger.info(f"Uploaded to {storage_path}")

        # Log to Firestore history
        logger.info("Logging metadata to Firestore...")
        resolution_str = f"{resolution[0]}x{resolution[1]}"
        db.collection("logs").document("test_captures").collection("history").add({
            "imageUrl": image_url,
            "resolution": resolution_str,
            "sizeBytes": file_size,
            "storagePath": storage_path,
            "timestamp": timestamp,
        })
        logger.info("Metadata logged")

        # Update status document
        logger.info("Updating test_capture status document...")
        db.document(config.TEST_CAPTURE_STATUS_PATH).set({
            "requested": False,
            "imageUrl": image_url,
            "resolution": resolution_str,
            "timestamp": timestamp,
        })
        logger.info("Status updated")

        # Cleanup local file
        logger.info("Cleaning up local file...")
        os.remove(filepath)
        filepath = None

        logger.info("=== TEST CAPTURE SUCCESSFUL ===")
        logger.info(f"Image URL: {image_url}")
        logger.info(f"Storage path: {storage_path}")

    except Exception as e:
        logger.error(f"Test capture failed: {e}")
        traceback.print_exc()
        
        # Try to write error to Firestore so app knows it failed
        try:
            db = init_firebase()[0]
            db.document(config.TEST_CAPTURE_STATUS_PATH).set({
                "requested": False,
                "error": str(e),
                "timestamp": config.get_timestamp_string(),
            })
            logger.info("Error status written to Firestore")
        except Exception as e2:
            logger.error(f"Could not write error to Firestore: {e2}")

    finally:
        # Cleanup
        if picam2:
            try:
                picam2.stop()
                picam2.close()
                logger.info("Camera stopped")
            except Exception as e:
                logger.warning(f"Error stopping camera: {e}")

        if filepath and os.path.exists(filepath):
            try:
                os.remove(filepath)
                logger.info("Cleaned up temp file")
            except Exception as e:
                logger.warning(f"Error removing temp file: {e}")


if __name__ == "__main__":
    try:
        take_test_capture()
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        traceback.print_exc()
        sys.exit(1)
