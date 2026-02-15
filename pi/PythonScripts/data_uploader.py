# -*- coding: utf-8 -*-
"""
FIREBASE BULK UPLOADER (High Cost, Infrequent Run) - BATCH WRITE IMPLEMENTED

This script reads all local CSV data, uploads it to Firestore using efficient 
**batch writes**, and then CLEARS the local file if the upload is successful.

CRITICAL FIXES: 
1. The timestamp is uploaded as a raw string to bypass parsing errors.
2. Writes are now grouped into atomic batches of up to 500 documents.
"""

import os
import sys
import csv
import traceback
import json 
from typing import Dict, Any, List

# --- CONFIGURATION (Shared Constants & Firebase) ---
LOCAL_LOG_FILE = "/home/wyattshore/Birdfeeder/Logs/energy_log.csv"
# CORRECT Firestore Collection path for data logs: logs/energy/data
ENERGY_DATA_COLLECTION_PATH = "logs/energy/data" 
SERVICE_ACCOUNT_PATH = "/home/wyattshore/Birdfeeder/birdfeeder-sa.json"
FIREBASE_PROJECT_ID = "birdfeeder-b6224" 
MAX_BATCH_SIZE = 500 # Firestore limit for a single batch operation

# Camera Server Status Check Configuration
CAMERA_STATUS_COLLECTION = "status"
CAMERA_STATUS_DOCUMENT = "camera_ip" 
CAMERA_STOPPED_FLAG = "STOPPED" # The value used when the server is intentionally off

# --- Heavy Imports ---
try:
    import firebase_admin
    from firebase_admin import credentials
    from firebase_admin import firestore
    from firebase_admin.firestore import client as FirestoreClient 
except ImportError:
    print("FATAL ERROR: Firebase Admin SDK not found.")
    sys.exit(1)

# Global Firebase Objects
db = None

# --- Helper Functions ---

def init_firebase():
    """Initializes the Firebase Admin SDK and returns the client."""
    global db

    if not os.path.exists(SERVICE_ACCOUNT_PATH):
        print(f"FATAL ERROR: Service Account file not found at {SERVICE_ACCOUNT_PATH}")
        return None

    try:
        cred = credentials.Certificate(SERVICE_ACCOUNT_PATH)
        if not firebase_admin._apps:
            firebase_admin.initialize_app(cred, {'projectId': FIREBASE_PROJECT_ID})
        
        db = firestore.client()
        print(">> Firebase client initialized.")
        return db

    except Exception as e:
        print(f"FATAL ERROR: Firebase initialization failed. Check credentials: {e}")
        return None

def is_camera_server_running(db_client: FirestoreClient) -> bool:
    """
    Checks the Firestore status document to see if the camera server is active.
    """
    try:
        doc_ref = db_client.collection(CAMERA_STATUS_COLLECTION).document(CAMERA_STATUS_DOCUMENT)
        doc_snapshot = doc_ref.get()
        
        if doc_snapshot.exists:
            status_data = doc_snapshot.to_dict()
            ip_address = status_data.get('ip_address', CAMERA_STOPPED_FLAG)
            
            if ip_address != CAMERA_STOPPED_FLAG:
                print(f">> Camera Server Detected RUNNING at IP: {ip_address}")
                return True
            else:
                return False
        
        return False

    except Exception as e:
        print(f"WARNING: Could not check camera status (Network Error): {e}")
        return False

def upload_local_data(db_client: FirestoreClient):
    """
    Reads local CSV, uploads all rows using Firestore batch writes, 
    and clears the file upon success.
    """

    if not os.path.exists(LOCAL_LOG_FILE) or os.stat(LOCAL_LOG_FILE).st_size == 0:
        print(">> Local buffer is empty. Nothing to upload.")
        return

    print(f">> Reading data from {LOCAL_LOG_FILE}...")
    data_rows = []
    
    # --- 1. Read and Prepare Data from CSV ---
    try:
        with open(LOCAL_LOG_FILE, 'r', newline='') as f:
            reader = csv.reader(f)
            header = next(reader)  # Skip header row
            for row in reader:
                if len(row) == 4:
                    try:
                        timestamp_string = row[0] # Raw string (e.g., "2025-11-06 21:03:00")
                        solar_v = float(row[1])
                        batt_v = float(row[2])
                        batt_p = float(row[3])
                        
                    except (ValueError, IndexError) as ve:
                        print(f"WARNING: Skipping row due to data/format error: {ve} - Row: {row}")
                        continue

                    data_rows.append({
                        "timestamp": timestamp_string,
                        "solar": {"voltage": solar_v},
                        "battery": {
                            "voltage": batt_v,
                            "percent": batt_p
                        }
                    })
    except Exception as e:
        print(f"FATAL ERROR: Failed to read CSV: {e}")
        traceback.print_exc(file=sys.stdout)
        return

    if not data_rows:
        print(">> No valid rows to upload.")
        return

    total_records = len(data_rows)
    print(f">> Preparing to upload {total_records} records using batching...")

    collection_ref = db_client.collection("logs").document("energy").collection("data")
    
    # --- 2. Perform Batch Upload ---
    batch = db_client.batch()
    records_processed_in_batch = 0
    total_successful_commits = 0
    upload_failed = False
    
    for i, record in enumerate(data_rows):
        
        # Get a new, unique document reference (Firestore assigns the ID)
        doc_ref = collection_ref.document()
        # Add the set operation to the current batch
        batch.set(doc_ref, record)
        records_processed_in_batch += 1
        
        # If the batch is full or we are at the end of the data, commit
        is_last_record = (i == total_records - 1)
        
        if records_processed_in_batch == MAX_BATCH_SIZE or is_last_record:
            try:
                # Commit the current batch
                batch.commit()
                total_successful_commits += records_processed_in_batch
                print(f"✅ Batch committed successfully. Uploaded {total_successful_commits}/{total_records} records so far.")
                
                # Start a new batch for the next set of records
                batch = db_client.batch()
                records_processed_in_batch = 0

            except Exception as e:
                # If a batch commit fails, the entire batch is rolled back.
                # We stop the process, retain the file, and log the failure.
                print(f"❌ FATAL BATCH COMMIT ERROR on record {i+1}: {e}")
                traceback.print_exc(file=sys.stdout)
                upload_failed = True
                break # Stop processing the rest of the records


    # --- 3. Cleanup ---
    if not upload_failed and total_successful_commits == total_records:
        os.remove(LOCAL_LOG_FILE)
        print(f"--- SUCCESS! Uploaded all {total_records} records and cleared local file. ---")
    else:
        print(f"--- FAILURE/INCOMPLETE! Uploaded {total_successful_commits}/{total_records} records. Local file retained for re-attempt. ---")

        
# --- Main Execution Block ---

if __name__ == "__main__":
    
    db_client = init_firebase()
    if db_client is None:
        sys.exit(1)
        
    if is_camera_server_running(db_client):
        print("\n!!! CAMERA SERVER IS ACTIVE. Aborting data upload to prevent crash/conflict.")
        sys.exit(0)
    
    print("-" * 50)
    print("Camera server inactive. Starting bulk data upload.")
    upload_local_data(db_client)
    print("-" * 50)
    
    sys.exit(0)