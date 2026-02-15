# -*- coding: utf-8 -*-
"""
STORAGE CLEANUP SCRIPT (Step 2.1 - Maintenance)

This script manages two distinct log collections:
1. SIGHTING LOGS: Deletes oldest entries (and their corresponding storage files) 
   to maintain a maximum total storage size.
2. ENERGY LOGS: Deletes entries older than a set retention period (e.g., 180 days).
"""

import os
import sys
import traceback
from datetime import datetime, timedelta, timezone

# Firebase Admin SDK imports
try:
    import firebase_admin
    from firebase_admin import credentials
    from firebase_admin import firestore
    from firebase_admin import storage
    # (Removed FieldFilter import — using simple .where() calls)
    from firebase_admin.exceptions import FirebaseError
except ImportError:
    print("FATAL ERROR: Firebase Admin SDK not found. Run: pip install firebase-admin")
    sys.exit(1)

# --- Configuration ---
SERVICE_ACCOUNT_PATH = "/home/wyattshore/Birdfeeder/birdfeeder-sa.json" # <--- CHECK THIS PATH!
FIREBASE_PROJECT_ID = "birdfeeder-b6224"
STORAGE_BUCKET_NAME = f"{FIREBASE_PROJECT_ID}.firebasestorage.app" 

# --- SIGHTING LOGS (SIZE-BASED) CONFIGURATION ---
# Target maximum storage size in Megabytes (4608 MB = 4.5 GB)
MAX_STORAGE_MB = 4608.0 
MAX_STORAGE_BYTES = MAX_STORAGE_MB * 1024 * 1024 
SIGHTINGS_COLLECTION = "logs/sightings/data" # Collection holding image metadata

# --- ENERGY LOGS (TIME-BASED) CONFIGURATION ---
ENERGY_DATA_COLLECTION = "logs/energy/data"  # Collection holding battery/solar/CPU data (normalize path)
ENERGY_DATA_RETENTION_DAYS = 7 # Keep data for 1 week

# Global Firebase Objects
db = None
storage_bucket = None

def init_firebase():
    """Initializes the Firebase Admin SDK."""
    global db, storage_bucket

    try:
        if not os.path.exists(SERVICE_ACCOUNT_PATH):
            print(f"FATAL ERROR: Service Account file not found at {SERVICE_ACCOUNT_PATH}")
            return False

        # 1. Initialize Credentials
        cred = credentials.Certificate(SERVICE_ACCOUNT_PATH)
        
        # 2. Initialize App
        if not firebase_admin._apps:
             firebase_admin.initialize_app(cred, {
                'projectId': FIREBASE_PROJECT_ID,
                'storageBucket': STORAGE_BUCKET_NAME
            })
        
        # 3. Initialize Services
        db = firestore.client()
        storage_bucket = storage.bucket()
        
        print(f">> Firebase initialized. Target Bucket: {STORAGE_BUCKET_NAME}")
        return True

    except Exception as e:
        print(f"FATAL ERROR: Firebase initialization failed. Check credentials/network: {e}")
        return False

def calculate_current_size(collection_ref):
    """Calculates the total size of files stored by summing fileSizeBytes in Firestore."""
    total_bytes = 0
    try:
        print(">> Calculating current Storage usage...")
        all_docs = collection_ref.stream()
        for doc in all_docs:
            data = doc.to_dict()
            total_bytes += data.get("fileSizeBytes", 0) 
        return total_bytes
    except Exception as e:
        print(f"? ERROR: Failed to calculate total storage size: {e}")
        traceback.print_exc(file=sys.stdout)
        return 0

def cleanup_sighting_logs():
    """Deletes old sighting logs and associated files to stay within MAX_STORAGE_MB."""
    
    collection_ref = db.collection(SIGHTINGS_COLLECTION)
    
    current_size_bytes = calculate_current_size(collection_ref)
    current_size_mb = current_size_bytes / (1024 * 1024) 

    print(f"\n--- Sighting Log Cleanup ---")
    print(f">> Current Sighting Storage Usage: {current_size_mb:.2f} MB (Target Max: {MAX_STORAGE_MB:.2f} MB)")
    
    if current_size_bytes <= MAX_STORAGE_BYTES:
        print("Sighting Log Cleanup complete: Usage is below limit. No action needed.")
        return

    # Cleanup is necessary
    bytes_to_free = current_size_bytes - MAX_STORAGE_BYTES
    bytes_to_free_mb = bytes_to_free / (1024 * 1024) 
    print(f"!! Storage OVER limit. Need to free up at least {bytes_to_free_mb:.2f} MB...")

    # 1. Query Firestore for the oldest logs 
    try:
        # Using FieldFilter to silence the UserWarning
        query = collection_ref.order_by("timestamp")
        docs = query.stream()
        documents_to_delete = [(doc.id, doc.to_dict()) for doc in docs]
    except Exception as e:
        print(f"? ERROR: Failed to query Sighting Logs for deletion candidates: {e}")
        traceback.print_exc(file=sys.stdout)
        return

    # 2. Process Deletions
    total_files_deleted = 0
    total_docs_deleted = 0
    total_size_freed_mb = 0.0
    freed_bytes_so_far = 0

    print(f"Attempting to delete {len(documents_to_delete)} documents, checking size threshold...")

    for doc_id, data in documents_to_delete:
        
        if freed_bytes_so_far >= bytes_to_free:
            print(f"\nTarget freed space reached! Stopping deletion.")
            break
            
        storage_path = data.get("storagePath")
        file_size_bytes = data.get("fileSizeBytes", 0) 

        # A. Delete from Firebase Storage
        if storage_path:
            try:
                blob = storage_bucket.blob(storage_path)
                blob.delete()
                total_files_deleted += 1
                
                size_mb = file_size_bytes / (1024 * 1024)
                total_size_freed_mb += size_mb
                freed_bytes_so_far += file_size_bytes

                print(f"  -> Deleted Storage file: {storage_path} (Freed: {size_mb:.2f} MB)")
            except Exception as e:
                print(f"  ? WARNING: Failed to delete file at {storage_path}. It might not exist: {e}")

        # B. Delete from Firestore Log
        try:
            db.collection(SIGHTINGS_COLLECTION).document(doc_id).delete()
            total_docs_deleted += 1
            print(f"  -> Deleted Firestore document: {doc_id}")
        except Exception as e:
            print(f"  ? ERROR: Failed to delete Firestore document {doc_id}: {e}")
            traceback.print_exc(file=sys.stdout)

    # 3. Summary
    final_usage_mb = (current_size_bytes - freed_bytes_so_far) / (1024 * 1024)
    print("\n--- Sighting Cleanup Summary ---")
    print(f"Files Deleted from Storage: {total_files_deleted}")
    print(f"Logs Deleted from Firestore: {total_docs_deleted}")
    print(f"Total Space Freed: {total_size_freed_mb:.2f} MB")
    print(f"Estimated Final Usage: {final_usage_mb:.2f} MB")
    print("--------------------------------\n")


def cleanup_energy_logs():
    """Deletes energy data logs older than the configured retention period."""
    print(f"\n--- Energy Log Cleanup ---")

    # 1. Calculate the cutoff time (180 days ago)
    retention_cutoff = datetime.now(timezone.utc) - timedelta(days=ENERGY_DATA_RETENTION_DAYS)
    
    print(f">> Deleting energy logs older than: {retention_cutoff.strftime('%Y-%m-%d %H:%M:%S')} UTC")

    # This collection path is now 'logs/energy/data'
    collection_ref = db.collection(ENERGY_DATA_COLLECTION)
    
    # 2. Query for documents older than the cutoff
    try:
        # Query documents with timestamp older than the cutoff (use 'filter' kwarg to avoid UserWarning)
        query = collection_ref.where(filter=("timestamp", "<", retention_cutoff))
        docs_to_delete = [doc.id for doc in query.stream()]
        
    except Exception as e:
        # This will now catch genuine query errors, not path errors
        print(f"? ERROR: Failed to query Energy Logs for deletion candidates: {e}")
        traceback.print_exc(file=sys.stdout)
        return

    # 3. Process Deletions
    total_deleted = 0
    if docs_to_delete:
        print(f"Found {len(docs_to_delete)} energy log documents older than {ENERGY_DATA_RETENTION_DAYS} days.")
        for doc_id in docs_to_delete:
            try:
                collection_ref.document(doc_id).delete()
                total_deleted += 1
            except Exception as e:
                print(f"  ? ERROR: Failed to delete Energy Log document {doc_id}: {e}")
        
    print(f"\n--- Energy Cleanup Summary ---")
    print(f"Total Energy Logs Deleted: {total_deleted}")
    print("------------------------------\n")


if __name__ == "__main__":
    if not init_firebase():
        sys.exit(1)

    # Run both cleanup routines
    cleanup_sighting_logs()
    cleanup_energy_logs()
