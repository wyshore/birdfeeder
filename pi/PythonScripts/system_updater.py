# -*- coding: utf-8 -*-
"""
CONFIG UPDATER & DATA UPLOAD CONTROLLER

Changes:
- Uses logging.
- Normalizes incoming Firestore config documents to the camera_server JSON schema.
- Saves normalized config to the local JSON file.
- NEW: Runs the data_uploader.py script immediately on startup and periodically 
       while the script is active (i.e., while the app is open).
- Keeps listener running until SIGTERM received.
"""
import os
import sys
import signal
import time
import json
import traceback
import threading
import logging
import subprocess # NEW: Required to run the data uploader script
from typing import Dict, Any

# Firebase Admin SDK imports
try:
    import firebase_admin
    from firebase_admin import credentials
    from firebase_admin import firestore
except ImportError:
    print("FATAL ERROR: Firebase Admin SDK not found. Run: pip install firebase-admin")
    sys.exit(1)

# --- CONFIGURATION ---
SERVICE_ACCOUNT_PATH = "/home/wyattshore/Birdfeeder/birdfeeder-sa.json"
FIREBASE_PROJECT_ID = "birdfeeder-b6224"
CONFIG_DOCUMENT_PATH = "config/settings"
LOCAL_CONFIG_FILE = "/home/wyattshore/Birdfeeder/local_app_settings.json"

# --- NEW DATA UPLOAD CONFIGURATION ---
DATA_UPLOADER_SCRIPT = "/home/wyattshore/Birdfeeder/PythonScripts/data_uploader.py"
UPLOAD_INTERVAL_SECONDS = 600
# Flag used to signal the data upload thread to stop gracefully
data_upload_stop_flag = threading.Event() 

# Logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("config_updater")

# Global Objects
db = None
main_thread_event = threading.Event()


# --- Utility Functions ---

def load_local_config():
    """Load settings from the local JSON file, or return defaults."""
    if os.path.exists(LOCAL_CONFIG_FILE):
        try:
            with open(LOCAL_CONFIG_FILE, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Failed to load local config: {e}. Using defaults.")

    # Favor a smaller, higher-framerate default so streaming is responsive.
    return {
        "stream_resolution": [640, 480],
        "snapshot_resolution": [1280, 720],
        "stream_framerate": 15,
        "exposure_time": 0,
        "controls": {"AwbEnable": True, "AeEnable": True}
    }


def save_local_config(settings: Dict[str, Any]):
    """Save settings to the local JSON file."""
    try:
        with open(LOCAL_CONFIG_FILE, 'w') as f:
            json.dump(settings, f, indent=4)
        logger.info("** CONFIG UPDATER: NEW SETTINGS SAVED LOCALLY **")
        logger.info(f"File: {LOCAL_CONFIG_FILE}")
        logger.info(f"Stream Resolution: {settings.get('stream_resolution')}")
        logger.info(f"Snapshot Resolution: {settings.get('snapshot_resolution')}")
        logger.info(f"Stream Framerate: {settings.get('stream_framerate')}")
    except Exception as e:
        logger.fatal(f"Could not save local config file: {e}")
        traceback.print_exc(file=sys.stdout)


def normalize_settings(doc_dict: Dict[str, Any]) -> Dict[str, Any]:
    """
    Map Firestore config document to camera_server expected schema.
    Accepts different input shapes and returns a safe dictionary.
    """
    out: Dict[str, Any] = {}

    # Stream resolution: "resolution", "stream_resolution"
    def parse_res(val):
        if isinstance(val, (list, tuple)) and len(val) >= 2:
            return [int(val[0]), int(val[1])]
        if isinstance(val, str) and 'x' in val:
            try:
                w, h = val.lower().split('x')
                return [int(w), int(h)]
            except Exception:
                return None
        return None

    res = doc_dict.get("resolution") or doc_dict.get("stream_resolution")
    parsed = parse_res(res)
    if parsed:
        out["stream_resolution"] = parsed

    snap = doc_dict.get("snapshot_resolution")
    parsed_snap = parse_res(snap) or out.get("stream_resolution")
    if parsed_snap:
        out["snapshot_resolution"] = parsed_snap

    if "stream_framerate" in doc_dict:
        try:
            out["stream_framerate"] = int(doc_dict.get("stream_framerate"))
        except Exception:
            pass

    if "exposure_time" in doc_dict:
        try:
            out["exposure_time"] = int(doc_dict.get("exposure_time"))
        except Exception:
            pass

    # Controls
    controls = doc_dict.get("controls")
    if isinstance(controls, dict):
        out["controls"] = controls

    # Accept explicit keys if already in target schema
    for k in ("stream_resolution", "snapshot_resolution", "stream_framerate", "exposure_time", "controls"):
        if k in doc_dict and k not in out:
            out[k] = doc_dict[k]

    return out


# --- NEW Data Upload Logic ---

def run_uploader():
    """Executes the data_uploader.py script using the current Python interpreter."""
    if not os.path.exists(DATA_UPLOADER_SCRIPT):
        logger.error(f"Data uploader script not found at: {DATA_UPLOADER_SCRIPT}")
        return

    try:
        # Use sys.executable (the VENV interpreter) for consistency
        cmd = [sys.executable, DATA_UPLOADER_SCRIPT]
        
        # Run the subprocess and wait for it to complete
        # We capture output to prevent it from clogging the stdout of this script
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)

        if result.returncode == 0:
            logger.info("ENERGY DATA UPLOAD: Successful.")
        else:
            logger.error(f"ENERGY DATA UPLOAD FAILED (Code: {result.returncode}). Error/Output: {result.stderr.strip() or result.stdout.strip()}")

    except Exception as e:
        logger.error(f"Exception during energy data upload run: {e}")


def data_upload_loop():
    """
    The thread target function for periodic data upload.
    Runs immediately, then every UPLOAD_INTERVAL_SECONDS.
    """
    logger.info("Data Upload Loop Thread started. Running initial upload...")
    
    # 1. Immediate upload upon startup (The "On Entry" requirement)
    run_uploader() 

    # 2. Periodic upload loop (The "During Viewing" requirement)
    while not data_upload_stop_flag.is_set():
        # Wait up to the interval, but check the stop flag periodically
        data_upload_stop_flag.wait(UPLOAD_INTERVAL_SECONDS)
        
        # If the flag was set while waiting, exit the loop
        if data_upload_stop_flag.is_set():
            break
            
        logger.info(f"ENERGY DATA UPLOAD: Running periodic upload after {UPLOAD_INTERVAL_SECONDS}s...")
        run_uploader()
    
    logger.info("Data Upload Loop Thread finished.")

# --- Firebase and Listener ---

def init_firebase():
    """Initializes Firebase Admin SDK and sets up the Firestore client."""
    global db
    if not os.path.exists(SERVICE_ACCOUNT_PATH):
        logger.fatal(f"Service Account file not found at {SERVICE_ACCOUNT_PATH}")
        return False

    try:
        cred = credentials.Certificate(SERVICE_ACCOUNT_PATH)
        app_name = 'config_updater_app'
        try:
            app_instance = firebase_admin.get_app(app_name)
        except ValueError:
            app_instance = firebase_admin.initialize_app(cred, {
                'projectId': FIREBASE_PROJECT_ID
            }, name=app_name)

        db = firestore.client(app_instance)
        logger.info("Config Updater: Firebase Admin initialized.")
        return True
    except Exception as e:
        logger.fatal(f"Firebase initialization failed in Config Updater: {e}")
        traceback.print_exc(file=sys.stdout)
        return False


def on_settings_snapshot(doc_snapshot, changes, read_time):
    """Callback function when the 'config/settings' document changes."""
    if not doc_snapshot:
        return

    try:
        logger.info("*** LISTENER CALLBACK FIRED: Processing settings update ***")
        doc_data = doc_snapshot[0].to_dict()
        if doc_data:
            logger.info(f"RECEIVED DATA: {json.dumps(doc_data)}")
            normalized = normalize_settings(doc_data)
            if normalized:
                # Merge with existing defaults to ensure keys present
                base = load_local_config()
                base.update(normalized)
                save_local_config(base)
            else:
                logger.warning("Received settings could not be normalized; ignoring.")
    except Exception as e:
        logger.fatal(f"Listener error in on_settings_snapshot: {e}")
        traceback.print_exc(file=sys.stdout)


# --- Signal Handling and Main Execution ---

def signal_handler(sig, frame):
    """Graceful shutdown sequence."""
    logger.info("Config Updater received shutdown signal (SIGTERM).")
    data_upload_stop_flag.set() # Stop the periodic upload thread
    main_thread_event.set() # Stop the main thread blocking event


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, signal_handler)

    if not init_firebase():
        sys.exit(1)

    # Start the data upload thread which runs immediately and then loops
    upload_thread = threading.Thread(target=data_upload_loop, daemon=True)
    upload_thread.start()
    logger.info("Periodic Data Upload Thread activated.")

    logger.info("Firebase initialization confirmed. Proceeding to config save.")

    initial_config = load_local_config()
    save_local_config(initial_config)

    logger.info(f"Attaching listener to document path: {CONFIG_DOCUMENT_PATH}")
    doc_ref = db.document(CONFIG_DOCUMENT_PATH)
    unsubscribe_func = doc_ref.on_snapshot(on_settings_snapshot)
    logger.info("Config Updater: Listener is now active.")

    try:
        # This will block until signal_handler calls main_thread_event.set()
        main_thread_event.wait()
    except Exception as e:
        logger.fatal(f"Error in main loop: {e}")
        traceback.print_exc(file=sys.stdout)
    finally:
        if unsubscribe_func:
            unsubscribe_func.unsubscribe()
        logger.info("Config Updater: Unsubscribed from Firestore and exiting.")
        sys.exit(0)