# -*- coding: utf-8 -*-
"""
CHECK FIRESTORE STATUS - Debug current Firestore state

Run this to check if app_is_open and test_capture status are set correctly.
Usage: python3 check_firestore_status.py
"""

import sys

# Import shared config
import shared_config as config

# Setup logging
logger = config.setup_logging("check_firestore")

# Firebase imports
try:
    from firebase_admin import firestore
except ImportError:
    logger.error("Firebase SDK not found")
    sys.exit(1)


def init_firebase():
    """Initialize Firebase."""
    try:
        db, _ = config.init_firebase(
            app_name='check_firestore_app',
            require_firestore=True,
            require_storage=False
        )
        logger.info("Firebase initialized")
        return db
    except Exception as e:
        logger.error(f"Firebase initialization failed: {e}")
        raise


def check_status():
    """Check current Firestore status."""
    logger.info("Checking Firestore status...")

    try:
        db = init_firebase()

        # Check app_is_open
        app_open_doc = db.document(config.APP_OPEN_STATUS_PATH).get()
        app_open_data = app_open_doc.to_dict() if app_open_doc.exists else None
        logger.info(f"app_is_open: {app_open_data}")

        # Check test_capture status
        test_capture_doc = db.document(config.TEST_CAPTURE_STATUS_PATH).get()
        test_capture_data = test_capture_doc.to_dict() if test_capture_doc.exists else None
        logger.info(f"test_capture: {test_capture_data}")

        # Check if system_updater should be running
        should_run = app_open_data and app_open_data.get('open', False)
        logger.info(f"system_updater should be running: {should_run}")

    except Exception as e:
        logger.error(f"Check failed: {e}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    check_status()