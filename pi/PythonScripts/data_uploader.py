# -*- coding: utf-8 -*-
"""
DATA UPLOADER - Firebase Bulk Upload

Reads local energy CSV data and uploads to Firestore using batch writes.
Clears local file upon successful upload.

Called by system_updater.py when app is open (immediate + periodic).
Uses efficient batching to minimize Firestore write costs.
"""

import os
import sys
import csv
import traceback

# Import shared configuration
import shared_config as config

# Setup logging
logger = config.setup_logging("data_uploader")

# Firebase imports
try:
    from firebase_admin import firestore
except ImportError:
    logger.error("FATAL: Firebase Admin SDK not found. Install: pip install firebase-admin")
    sys.exit(1)

# Global Firebase client
db = None

# Firestore batch size limit
MAX_BATCH_SIZE = 500


def init_firebase() -> bool:
    """
    Initialize Firebase Admin SDK.

    Returns:
        bool: True if successful, False otherwise
    """
    global db

    try:
        db, _ = config.init_firebase(
            app_name='data_uploader_app',
            require_firestore=True,
            require_storage=False
        )
        logger.info("Firebase initialized successfully")
        return True

    except Exception as e:
        logger.error(f"Firebase initialization failed: {e}")
        traceback.print_exc()
        return False


def upload_local_data() -> None:
    """
    Read local CSV and upload all rows using Firestore batch writes.
    Clears file upon success.
    """
    # Check if file exists and has data
    if not os.path.exists(config.ENERGY_LOG_FILE):
        logger.info("No local energy log file found - nothing to upload")
        return

    if os.stat(config.ENERGY_LOG_FILE).st_size == 0:
        logger.info("Local energy log is empty - nothing to upload")
        return

    logger.info(f"Reading data from {config.ENERGY_LOG_FILE}")
    data_rows = []

    # Read and parse CSV
    try:
        with open(config.ENERGY_LOG_FILE, 'r', newline='') as f:
            reader = csv.reader(f)
            header = next(reader)  # Skip header

            for row in reader:
                if len(row) != 4:
                    logger.warning(f"Skipping malformed row: {row}")
                    continue

                try:
                    timestamp_str = row[0]
                    solar_v = float(row[1])
                    battery_v = float(row[2])
                    battery_p = float(row[3])

                    data_rows.append({
                        "timestamp": timestamp_str,
                        "solar": {"voltage": solar_v},
                        "battery": {
                            "voltage": battery_v,
                            "percent": battery_p
                        }
                    })

                except (ValueError, IndexError) as e:
                    logger.warning(f"Skipping row due to parse error: {e} - Row: {row}")
                    continue

    except Exception as e:
        logger.error(f"Failed to read CSV: {e}")
        traceback.print_exc()
        return

    if not data_rows:
        logger.warning("No valid rows found in CSV")
        return

    total_records = len(data_rows)
    logger.info(f"Uploading {total_records} records using batch writes")

    # Get collection reference
    collection_ref = db.collection("logs").document("energy").collection("data")

    # Batch upload
    batch = db.batch()
    records_in_batch = 0
    total_uploaded = 0
    upload_failed = False

    for i, record in enumerate(data_rows):
        # Add to batch
        doc_ref = collection_ref.document()  # Auto-generated ID
        batch.set(doc_ref, record)
        records_in_batch += 1

        # Commit when batch is full or at end
        is_last_record = (i == total_records - 1)

        if records_in_batch == MAX_BATCH_SIZE or is_last_record:
            try:
                batch.commit()
                total_uploaded += records_in_batch
                logger.info(f"Batch committed: {total_uploaded}/{total_records} records uploaded")

                # Start new batch
                batch = db.batch()
                records_in_batch = 0

            except Exception as e:
                logger.error(f"Batch commit failed at record {i+1}: {e}")
                traceback.print_exc()
                upload_failed = True
                break

    # Cleanup
    if not upload_failed and total_uploaded == total_records:
        try:
            os.remove(config.ENERGY_LOG_FILE)
            logger.info(f"SUCCESS: Uploaded all {total_records} records and cleared local file")
        except Exception as e:
            logger.warning(f"Uploaded successfully but failed to delete file: {e}")
    else:
        logger.error(f"FAILURE: Uploaded {total_uploaded}/{total_records} records - file retained")


if __name__ == "__main__":
    # Initialize Firebase
    if not init_firebase():
        logger.error("Exiting due to Firebase initialization failure")
        sys.exit(1)

    # Upload data
    logger.info("=" * 60)
    logger.info("Starting energy data upload")
    upload_local_data()
    logger.info("=" * 60)

    sys.exit(0)
