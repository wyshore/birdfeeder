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
main_thread_event = threading.Event()
data_upload_stop_flag = threading.Event()


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
        "stream_framerate": config.DEFAULT_FRAMERATE,
        "exposure_time": 0,
        "controls": {"AwbEnable": True, "AeEnable": True}
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

    # Stream framerate
    if "stream_framerate" in doc_dict:
        try:
            out["stream_framerate"] = int(doc_dict["stream_framerate"])
        except Exception:
            pass

    # Exposure time
    if "exposure_time" in doc_dict:
        try:
            out["exposure_time"] = int(doc_dict["exposure_time"])
        except Exception:
            pass

    # Camera controls
    controls = doc_dict.get("controls")
    if isinstance(controls, dict):
        out["controls"] = controls

    # Accept explicit keys if already in target schema
    for key in ("stream_resolution", "snapshot_resolution", "stream_framerate", "exposure_time", "controls"):
        if key in doc_dict and key not in out:
            out[key] = doc_dict[key]

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


def data_upload_loop() -> None:
    """
    Periodic data upload thread.
    Runs immediately on startup, then every DATA_UPLOAD_INTERVAL seconds.
    """
    logger.info("Data upload thread started - running initial upload")

    # Immediate upload on startup
    run_uploader()

    # Periodic upload loop
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
    Initialize Firebase Admin SDK.

    Returns:
        True if successful, False otherwise
    """
    global db

    try:
        db, _ = config.init_firebase(
            app_name='system_updater_app',
            require_firestore=True,
            require_storage=False
        )
        logger.info("Firebase initialized successfully")
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

    # Setup Firestore listener
    logger.info(f"Attaching listener to: {config.CONFIG_SETTINGS_PATH}")
    doc_ref = db.document(config.CONFIG_SETTINGS_PATH)
    unsubscribe_func = doc_ref.on_snapshot(on_settings_snapshot)
    logger.info("System updater active - listening for config changes")
    logger.info("-" * 60)

    try:
        # Block until shutdown signal received
        main_thread_event.wait()

    except Exception as e:
        logger.error(f"Error in main loop: {e}")
        traceback.print_exc()

    finally:
        # Clean shutdown
        if unsubscribe_func:
            try:
                unsubscribe_func.unsubscribe()
            except Exception:
                pass

        logger.info("System updater shutdown complete")
        sys.exit(0)
