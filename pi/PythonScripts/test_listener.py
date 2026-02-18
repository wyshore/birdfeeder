# -*- coding: utf-8 -*-
"""
TEST LISTENER - Verify Firestore listener is working

Run this to test if the system_updater listener can detect test capture requests.
Usage: python3 test_listener.py
"""

import sys
import time
import signal
import threading

# Import shared config
import shared_config as config

# Setup logging
logger = config.setup_logging("test_listener")

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
            app_name='test_listener_app',
            require_firestore=True,
            require_storage=False
        )
        logger.info("Firebase initialized")
        return db
    except Exception as e:
        logger.error(f"Firebase initialization failed: {e}")
        raise


def on_test_capture_snapshot(doc_snapshot, changes, read_time):
    """Test listener callback."""
    logger.info("=== LISTENER TRIGGERED ===")

    if not doc_snapshot:
        logger.info("No document snapshot")
        return

    try:
        doc_data = doc_snapshot.to_dict()
        logger.info(f"Document data: {doc_data}")

        if doc_data and doc_data.get("requested", False):
            logger.info("Test capture request detected!")
        else:
            logger.info("No test capture request")

    except Exception as e:
        logger.error(f"Listener error: {e}")


def main():
    """Test the listener."""
    logger.info("Starting test listener...")

    try:
        db = init_firebase()

        # Setup listener
        test_capture_ref = db.document(config.TEST_CAPTURE_STATUS_PATH)
        unsubscribe = test_capture_ref.on_snapshot(on_test_capture_snapshot)

        logger.info(f"Listening on: {config.TEST_CAPTURE_STATUS_PATH}")
        logger.info("Press Ctrl+C to stop")

        # Keep running
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            logger.info("Stopping listener...")

        # Cleanup
        unsubscribe.unsubscribe()
        logger.info("Listener stopped")

    except Exception as e:
        logger.error(f"Test failed: {e}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    main()