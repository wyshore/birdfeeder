# -*- coding: utf-8 -*-

import os
import time
import sys
import json
import traceback 
from datetime import datetime
import threading # <<< New import for the timer
import signal 

# --- Hardware Library Imports ---
try:
    from picamera2 import Picamera2
    from gpiozero import MotionSensor
except ImportError as e:
    print("FATAL ERROR: Hardware libraries (Picamera2 or gpiozero) not found.")
    print("Please ensure they are installed: pip install picamera2 gpiozero")
    print(f"Error details: {e}")
    sys.exit(1)

# Firebase Admin SDK imports
try:
    import firebase_admin
    from firebase_admin import credentials
    from firebase_admin import firestore
    from firebase_admin import storage
    from firebase_admin.exceptions import FirebaseError
except ImportError:
    print("FATAL ERROR: Firebase Admin SDK not found. Run: pip install firebase-admin")
    sys.exit(1)


# --- Configuration (UPDATE THESE VALUES ON YOUR PI) ---
SERVICE_ACCOUNT_PATH = "/home/wyattshore/Birdfeeder/birdfeeder-sa.json"
FIREBASE_PROJECT_ID = "birdfeeder-b6224"
STORAGE_BUCKET_NAME = f"{FIREBASE_PROJECT_ID}.firebasestorage.app" 

# Camera and Motion Setup
RESOLUTION = (4608, 2592)
MOTION_PIN = 4
CAMERA_WARMUP_TIME = 1.0 
DEBOUNCE_DELAY = 0.2 
MIN_PULSE_DURATION = 6.5 # <<< CRITICAL: The delay before capture executes

# Local directory where pictures will be saved before upload attempt (The Queue)
LOCAL_QUEUE_FOLDER = os.path.expanduser("~/upload_queue") 
SIGHTINGS_STORAGE_FOLDER = "media/sightings/"

# Global Firebase and Hardware Objects (Initialized below)
db = None
storage_bucket = None
picam2 = None
is_capturing = False # Flag to prevent multiple captures if camera is busy
delayed_capture_timer = None # Tracks the background timer thread


def init_firebase():
    """Initializes the Firebase Admin SDK."""
    global db, storage_bucket
    # ... (init_firebase remains the same)
    try:
        if not os.path.exists(SERVICE_ACCOUNT_PATH):
            print(f"FATAL ERROR: Service Account file not found at {SERVICE_ACCOUNT_PATH}")
            sys.exit(1)
        cred = credentials.Certificate(SERVICE_ACCOUNT_PATH)
        firebase_admin.initialize_app(cred, {
            'projectId': FIREBASE_PROJECT_ID,
            'storageBucket': STORAGE_BUCKET_NAME
        })
        db = firestore.client()
        storage_bucket = storage.bucket()
        print(">> Firebase (Firestore/Storage) successfully initialized.")
        return True
    except Exception as e:
        print(f"FATAL ERROR: Firebase initialization failed. Check credentials and network: {e}")
        return False

def init_hardware():
    """Sets up Picamera2 configuration but DOES NOT start the sensor."""
    global picam2
    # ... (init_hardware remains the same)
    try:
        picam2 = Picamera2()
        config = picam2.create_still_configuration(main={"size": RESOLUTION})
        picam2.configure(config)
        print(f">> Camera configured at resolution: {RESOLUTION}.")
        return True
    except Exception as e:
        print(f"FATAL ERROR: Hardware initialization failed. Check camera ribbon/GPIO wiring: {e}")
        return False

def upload_and_log(filepath, filename, timestamp):
    """Handles file upload to Storage and metadata logging to Firestore."""
    # ... (upload_and_log remains the same)
    if not db or not storage_bucket:
        print("Warning: Skipping upload/log. Firebase services not initialized.")
        return False
    storage_path = f"{SIGHTINGS_STORAGE_FOLDER}{filename}" 
    image_url = None
    try:
        file_size_bytes = os.path.getsize(filepath)
        print(f"-> Local file size measured: {round(file_size_bytes / 1024 / 1024, 2)} MB")
    except Exception:
        file_size_bytes = 0 
    try:
        blob = storage_bucket.blob(storage_path)
        blob.upload_from_filename(filepath)
        blob.make_public()
        image_url = blob.public_url
        print(f"-> Uploaded capture to storage: {storage_path}")
    except Exception as e:
        print(f"? ERROR: Failed to upload {filename} to Firebase Storage: {e}")
        os.rename(filepath, os.path.join(LOCAL_QUEUE_FOLDER, filename))
        return False
    try:
        db.collection("logs").document("motion_captures").collection("data").add({
            "imageUrl": image_url,
            "resolution": f"{RESOLUTION[0]}x{RESOLUTION[1]}",
            "sizeBytes": file_size_bytes, 
            "storagePath": storage_path,
            "timestamp": timestamp,
        })
        print("-> Logged metadata to Firestore: logs/motion_captures/data")
        os.remove(filepath)
        print("-> Cleaned up local file.")
        return True
    except Exception as e:
        print(f"? ERROR: Failed to log metadata to Firestore: {e}")
        traceback.print_exc(file=sys.stdout)
        return False

def capture_sequence():
    """
    Handles the photo capture, upload, and logging. 
    Called by the timer thread AFTER 6.5s of sustained motion.
    """
    global is_capturing, delayed_capture_timer
    
    if is_capturing:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] - Timer expired, but camera is busy. Skipping.")
        return 

    is_capturing = True
    print(f"\n[{datetime.now().strftime('%H:%M:%S')}] --- TIMER EXPIRED: SUSTAINED MOTION CONFIRMED. CAPTURING... ---")
    
    try:
        # 1. POWER ON THE CAMERA SENSOR
        picam2.start()
        print(f"-> Camera started. Waiting {CAMERA_WARMUP_TIME}s for stable image.")
        time.sleep(CAMERA_WARMUP_TIME) 
        
        # a. Setup Filenames
        now = datetime.now()
        timestamp = now.strftime("%Y-%m-%d %H:%M:%S")
        filename = f"bird_{now.strftime('%Y%m%d-%H%M%S')}.jpg"
        filepath = os.path.join(LOCAL_QUEUE_FOLDER, filename) 
        
        # b. Capture and Save Locally
        picam2.capture_file(filepath)
        print(f"-> Photo saved locally to queue: {filepath}")
        
        # c. Upload and Log 
        upload_and_log(filepath, filename, timestamp)
            
    except Exception as e:
        print(f"? CRITICAL CAPTURE/UPLOAD ERROR: {e}")
        traceback.print_exc(file=sys.stdout)

    finally:
        # 2. POWER OFF THE CAMERA SENSOR
        try:
            picam2.stop()
            print("-> Camera stopped/powered down.")
        except Exception as e:
            print(f"Warning: Could not stop camera properly: {e}")
            
        is_capturing = False
        print("--- Capture sequence complete. Waiting for new motion. ---")


# --- Handlers for Threaded Timer Logic ---

def motion_started():
    """
    Handler for pir.when_motion. Starts the threaded timer.
    """
    global delayed_capture_timer, is_capturing

    if is_capturing:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] - Motion detected, but capture is running. Ignoring.")
        return

    # Cancel any existing, pending timer (shouldn't happen, but good practice)
    if delayed_capture_timer and delayed_capture_timer.is_alive():
        delayed_capture_timer.cancel()
        print(f"[{datetime.now().strftime('%H:%M:%S')}] - Motion re-detected, restarting {MIN_PULSE_DURATION}s timer.")
    
    # 1. Start the timer thread
    delayed_capture_timer = threading.Timer(MIN_PULSE_DURATION, capture_sequence)
    # Allows the timer thread to exit when the main program exits
    delayed_capture_timer.daemon = True 
    delayed_capture_timer.start()
    
    print(f"\n[{datetime.now().strftime('%H:%M:%S')}] --- Motion detected! {MIN_PULSE_DURATION}s timer started. ---")


def motion_ended():
    """
    Handler for pir.when_no_motion. Cancels the timer if motion stops early.
    """
    global delayed_capture_timer
    
    if delayed_capture_timer and delayed_capture_timer.is_alive():
        # Motion stopped before the 6.5s delay expired. Cancel the capture.
        delayed_capture_timer.cancel()
        print(f"[{datetime.now().strftime('%H:%M:%S')}] - Motion stopped early. Timer cancelled. False positive filtered.")
        
    # Reset the global variable after cancelling
    delayed_capture_timer = None


# --- Main Execution (Updated GPIO Setup) ---
if __name__ == "__main__":
    
    # 1. Setup Local Queue Environment
    if not os.path.exists(LOCAL_QUEUE_FOLDER):
        os.makedirs(LOCAL_QUEUE_FOLDER)
        print(f"Created local upload queue folder: {LOCAL_QUEUE_FOLDER}")

    # 2. Firebase Setup
    if not init_firebase():
        sys.exit(1)
        
    # 3. Camera Configuration
    if not init_hardware():
        print("Exiting due to critical hardware failure.")
        sys.exit(1)

    # 4. GPIO Setup
    try:
        # Initialize MotionSensor.
        pir = MotionSensor(MOTION_PIN, threshold=DEBOUNCE_DELAY)
        
        # Attach the custom timer start and cancel functions
        pir.when_motion = motion_started
        pir.when_no_motion = motion_ended 
        
        print(f"\n>> Motion detection ready on BCM Pin {MOTION_PIN} using gpiozero.")
        print(f">> Capture Delay Filter: Capture occurs after {MIN_PULSE_DURATION} seconds of continuous motion.")
        print(">> Camera is OFF (low-power state). Monitoring is ACTIVE. Press CTRL+C to exit.")
        print("-" * 50)

        # 5. Keep the main script running efficiently, waiting for events
        signal.pause()

    except KeyboardInterrupt:
        print("\nExiting program by user request...")
    except Exception as e:
        print(f"An unexpected runtime error occurred: {e}")
        traceback.print_exc(file=sys.stdout)
    finally:
        # Cleanup the timer and camera
        if delayed_capture_timer and delayed_capture_timer.is_alive():
            delayed_capture_timer.cancel()
        if picam2 and picam2.started:
            picam2.stop()
        print("Cleanup complete. Exiting.")