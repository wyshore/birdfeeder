# -*- coding: utf-8 -*-
"""
SHARED CONFIGURATION MODULE

Centralized configuration for all birdfeeder Python scripts.
This module provides:
- Firebase credentials and initialization
- Firestore document paths
- Storage bucket configuration
- Hardware constants
- File paths and directories
- Logging configuration

All scripts should import from this module instead of hardcoding values.
"""

import os
import sys
import logging
from typing import Optional

# ============================================================================
# FIREBASE CREDENTIALS
# ============================================================================

# Path to service account JSON file
SERVICE_ACCOUNT_PATH = "/home/wyattshore/Birdfeeder/pi/birdfeeder-sa.json"

# Firebase project ID
FIREBASE_PROJECT_ID = "birdfeeder-b6224"

# Storage bucket name
STORAGE_BUCKET_NAME = f"{FIREBASE_PROJECT_ID}.firebasestorage.app"


# ============================================================================
# FIRESTORE DOCUMENT PATHS
# ============================================================================

# Status documents
STREAMING_STATUS_PATH = "status/streaming_enabled"
APP_OPEN_STATUS_PATH = "status/app_is_open"
HEARTBEAT_STATUS_PATH = "status/heartbeat"

# Config documents
CONFIG_SETTINGS_PATH = "config/settings"

# Log collections
ENERGY_DATA_COLLECTION = "logs/energy/data"
MOTION_CAPTURES_COLLECTION = "logs/motion_captures/data"
SNAPSHOTS_COLLECTION = "logs/snapshots/data"
SIGHTINGS_COLLECTION = "logs/sightings/data"
TEST_CAPTURE_STATUS_PATH = "status/test_capture"
TEST_CAPTURES_COLLECTION = "logs/test_captures/history"
BATCH_UPLOAD_REQUEST_PATH = "status/batch_upload_request"


# ============================================================================
# FIREBASE STORAGE PATHS
# ============================================================================

SIGHTINGS_STORAGE_PATH = "media/sightings"
SNAPSHOTS_STORAGE_PATH = "media/snapshots"
TEST_CAPTURES_STORAGE_PATH = "media/test_captures"
MAX_TEST_CAPTURES = 5


# ============================================================================
# SCRIPT PATHS
# ============================================================================

# Base directory for all scripts
SCRIPTS_DIR = "/home/wyattshore/Birdfeeder/pi/PythonScripts"

# Individual script paths
CAMERA_SERVER_SCRIPT = os.path.join(SCRIPTS_DIR, "camera_server.py")
SYSTEM_UPDATER_SCRIPT = os.path.join(SCRIPTS_DIR, "system_updater.py")
MOTION_CAPTURE_SCRIPT = os.path.join(SCRIPTS_DIR, "motion_capture.py")
DATA_UPLOADER_SCRIPT = os.path.join(SCRIPTS_DIR, "data_uploader.py")


# ============================================================================
# PID FILES
# ============================================================================

PID_DIR = "/tmp"

CAMERA_SERVER_PID_FILE = os.path.join(PID_DIR, "camera_server.pid")
SYSTEM_UPDATER_PID_FILE = os.path.join(PID_DIR, "config_updater.pid")
MOTION_CAPTURE_PID_FILE = os.path.join(PID_DIR, "motion_capture.pid")


# ============================================================================
# LOCAL FILE PATHS
# ============================================================================

# Base directory for birdfeeder files
BASE_DIR = "/home/wyattshore/Birdfeeder/pi"

# Local config file for camera settings
LOCAL_CONFIG_FILE = os.path.join(BASE_DIR, "local_app_settings.json")

# Queue folder for photos awaiting upload
UPLOAD_QUEUE_DIR = os.path.join(BASE_DIR, "upload_queue")

# Log directory
LOGS_DIR = os.path.join(BASE_DIR, "Logs")


# ============================================================================
# HARDWARE CONSTANTS
# ============================================================================

# PIR Motion Sensor
MOTION_PIN = 4
DEBOUNCE_DELAY = 0.2
MIN_PULSE_DURATION = 6.5  # Seconds of sustained motion before capture

# Camera Settings
DEFAULT_CAPTURE_RESOLUTION = (4608, 2592)  # Full resolution for motion capture
DEFAULT_STREAM_RESOLUTION = (640, 360)      # Low-res for live streaming
DEFAULT_SNAPSHOT_RESOLUTION = (2560, 1440)  # High-res for manual snapshots
DEFAULT_FRAMERATE = 10
CAMERA_WARMUP_TIME = 1.0

# Camera Controls (Picamera2 control names → default values)
# These are applied during motion capture and can be overridden via the app.
# Values use Picamera2's native control names for direct use with set_controls().
DEFAULT_CAMERA_CONTROLS = {
    "AfMode": 2,              # 0=manual, 1=single, 2=continuous
    "AeEnable": True,         # Auto exposure on
    "AwbEnable": True,        # Auto white balance on
    "AwbMode": 0,             # 0=auto, 1=incandescent, 2=tungsten, 3=fluorescent, 4=indoor, 5=daylight, 6=cloudy
    "Sharpness": 1.0,         # 0.0 - 16.0
    "Contrast": 1.0,          # 0.0 - 32.0
    "Saturation": 1.0,        # 0.0 - 32.0
    "Brightness": 0.0,        # -1.0 - 1.0
    "NoiseReductionMode": 2,  # 0=off, 1=fast, 2=high_quality
}

# ADC (ADS1115) Configuration
ADC_ADDRESS = 0x48
ADC_GAIN = 2/3  # Gain multiplier for ADS1115
SOLAR_VOLTAGE_CHANNEL = 0  # A0
BATTERY_VOLTAGE_CHANNEL = 1  # A1
SOLAR_VOLTAGE_DIVIDER = 2.419
BATTERY_VOLTAGE_DIVIDER = 1.435

# Battery Management
BATTERY_MAX_VOLTAGE = 4.2
BATTERY_MIN_VOLTAGE = 3.2

# Energy Logging
ENERGY_LOG_FILE = os.path.join(LOGS_DIR, "energy_log.csv")


# ============================================================================
# TIMING CONSTANTS
# ============================================================================

HEARTBEAT_INTERVAL = 60  # Seconds between heartbeat updates
DATA_UPLOAD_INTERVAL = 600  # Seconds between energy data uploads (10 minutes)


# ============================================================================
# CAMERA SERVER NETWORK SETTINGS
# ============================================================================

CAMERA_SERVER_ADDRESS = '0.0.0.0'
CAMERA_SERVER_PORT = 8000


# ============================================================================
# LOGGING CONFIGURATION
# ============================================================================

LOG_FORMAT = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
LOG_DATE_FORMAT = "%Y-%m-%d %H:%M:%S"
LOG_LEVEL = logging.INFO


def setup_logging(logger_name: str, level: int = LOG_LEVEL) -> logging.Logger:
    """
    Configure and return a logger with consistent formatting.

    Args:
        logger_name: Name for the logger (typically __name__ or script name)
        level: Logging level (default: INFO)

    Returns:
        Configured logger instance
    """
    logger = logging.getLogger(logger_name)
    logger.setLevel(level)

    # Only add handler if logger doesn't have one already
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setLevel(level)
        formatter = logging.Formatter(LOG_FORMAT, datefmt=LOG_DATE_FORMAT)
        handler.setFormatter(formatter)
        logger.addHandler(handler)

    return logger


# ============================================================================
# FIREBASE INITIALIZATION
# ============================================================================

# Global Firebase objects (initialized once by init_firebase())
_firebase_app = None
_firestore_client = None
_storage_bucket = None


def init_firebase(app_name: Optional[str] = None,
                  require_firestore: bool = True,
                  require_storage: bool = False) -> tuple:
    """
    Initialize Firebase Admin SDK with centralized configuration.

    This function creates a single Firebase app instance and returns
    clients for Firestore and/or Storage as needed. It uses a singleton
    pattern to avoid creating multiple app instances.

    Args:
        app_name: Optional name for the Firebase app (for multiple apps)
        require_firestore: Whether to initialize Firestore client
        require_storage: Whether to initialize Storage client

    Returns:
        tuple: (db, bucket) where:
            - db is firestore.Client or None
            - bucket is storage.Bucket or None

    Raises:
        FileNotFoundError: If service account file doesn't exist
        Exception: If Firebase initialization fails
    """
    global _firebase_app, _firestore_client, _storage_bucket

    # Check if service account file exists
    if not os.path.exists(SERVICE_ACCOUNT_PATH):
        raise FileNotFoundError(
            f"Service account file not found at {SERVICE_ACCOUNT_PATH}"
        )

    try:
        import firebase_admin
        from firebase_admin import credentials

        # Initialize Firebase app if not already done
        if _firebase_app is None:
            cred = credentials.Certificate(SERVICE_ACCOUNT_PATH)
            config = {
                'projectId': FIREBASE_PROJECT_ID,
            }

            # Add storage bucket to config if needed
            if require_storage:
                config['storageBucket'] = STORAGE_BUCKET_NAME

            # Use provided app name or default
            if app_name:
                try:
                    _firebase_app = firebase_admin.get_app(app_name)
                except ValueError:
                    _firebase_app = firebase_admin.initialize_app(
                        cred, config, name=app_name
                    )
            else:
                # Use default app
                if not firebase_admin._apps:
                    _firebase_app = firebase_admin.initialize_app(cred, config)
                else:
                    _firebase_app = firebase_admin.get_app()

        # Initialize Firestore client if requested and not already done
        db = None
        if require_firestore:
            if _firestore_client is None:
                from firebase_admin import firestore
                _firestore_client = firestore.client(_firebase_app)
            db = _firestore_client

        # Initialize Storage client if requested and not already done
        bucket = None
        if require_storage:
            if _storage_bucket is None:
                from firebase_admin import storage
                _storage_bucket = storage.bucket(
                    STORAGE_BUCKET_NAME,
                    app=_firebase_app
                )
            bucket = _storage_bucket

        return db, bucket

    except ImportError:
        raise ImportError(
            "Firebase Admin SDK not found. Install with: pip install firebase-admin"
        )
    except Exception as e:
        raise Exception(f"Firebase initialization failed: {e}")


def get_firestore_client():
    """Get the Firestore client (must call init_firebase first)."""
    if _firestore_client is None:
        raise RuntimeError("Firestore not initialized. Call init_firebase() first.")
    return _firestore_client


def get_storage_bucket():
    """Get the Storage bucket (must call init_firebase first)."""
    if _storage_bucket is None:
        raise RuntimeError("Storage not initialized. Call init_firebase() first.")
    return _storage_bucket


# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

def ensure_directory_exists(directory_path: str) -> None:
    """
    Create directory if it doesn't exist.

    Args:
        directory_path: Path to directory to create
    """
    if not os.path.exists(directory_path):
        os.makedirs(directory_path, exist_ok=True)


def get_timestamp_filename(prefix: str = "file", extension: str = "jpg") -> str:
    """
    Generate a filename with current timestamp.

    Args:
        prefix: Filename prefix
        extension: File extension (without dot)

    Returns:
        Filename string like "prefix_20240215_143022.extension"
    """
    from datetime import datetime
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return f"{prefix}_{timestamp}.{extension}"


def get_timestamp_string() -> str:
    """
    Get current timestamp as formatted string.

    Returns:
        Timestamp string like "2024-02-15 14:30:22"
    """
    from datetime import datetime
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


# ============================================================================
# INITIALIZATION CHECK
# ============================================================================

# Ensure critical directories exist when module is imported
for directory in [UPLOAD_QUEUE_DIR, LOGS_DIR]:
    ensure_directory_exists(directory)
