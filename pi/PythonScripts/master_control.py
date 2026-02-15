# -*- coding: utf-8 -*-
"""
MASTER CONTROL LISTENER (Always On, Low Power)

Full updated implementation:
- Monitors 'config/settings' for motion_capture_enabled flag.
- Manages the lifecycle of camera_server, config_updater, and motion_capture scripts.
- IMPLEMENTS MUTUAL EXCLUSION: Camera Server (streaming) will forcefully stop
  Motion Capture, and automatically restart it when streaming finishes.
"""
import os
import sys
import signal
import time
import subprocess
import traceback
import logging
import select
from datetime import datetime

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

# Firestore Paths to Monitor (Service Lifecycle Control)
STREAMING_STATUS_PATH = "status/streaming_enabled"
APP_OPEN_STATUS_PATH = "status/app_is_open"
CONFIG_SETTINGS_PATH = "config/settings"

# Script Paths
CAMERA_SERVER_SCRIPT = "/home/wyattshore/Birdfeeder/PythonScripts/camera_server.py"
SYSTEM_UPDATER_SCRIPT = "/home/wyattshore/Birdfeeder/PythonScripts/system_updater.py"
MOTION_CAPTURE_SCRIPT = "/home/wyattshore/Birdfeeder/PythonScripts/motion_capture.py"

# PID Files
CAMERA_SERVER_PID_FILE = "/tmp/camera_server.pid"
SYSTEM_UPDATER_PID_FILE = "/tmp/config_updater.pid"
MOTION_CAPTURE_PID_FILE = "/tmp/motion_capture.pid"

# Logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("stream_listener")

# Global Variables
db = None
camera_server_process = None
config_updater_process = None
motion_capture_process = None
current_streaming_enabled_state = False
current_app_open_state = False
current_motion_capture_enabled_state = False
# Flag to track if Motion Capture was stopped specifically by a streaming request.
motion_capture_paused_by_stream = False


# --- Helper Functions ---

def get_ip_address():
    """Returns the primary local IP address using hostname -I."""
    try:
        # Runs 'hostname -I', takes the first IP, and strips whitespace
        output = subprocess.check_output(['hostname', '-I']).decode('utf-8').strip()
        return output.split()[0] if output else '127.0.0.1'
    except Exception as e:
        logger.warning(f"Could not determine IP via hostname -I: {e}")
        return '127.0.0.1'
    
def _pid_matches_script(pid: int, script_path: str) -> bool:
    """Return True if /proc/<pid>/cmdline contains script_path (basic safety check)."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmdline = f.read().decode(errors='ignore')
            return script_path in cmdline or os.path.basename(script_path) in cmdline
    except Exception:
        return False


def start_process(script_path, pid_file, interpreter=None):
    """
    Starts a Python script as a background process using Popen.
    Returns the subprocess object.
    """
    if os.path.exists(pid_file):
        logger.warning(f"PID file found ({os.path.basename(pid_file)}). Attempting to clean up.")
        try:
            with open(pid_file, 'r') as f:
                pid = int(f.read().strip())
            if _pid_matches_script(pid, script_path):
                try:
                    os.kill(pid, signal.SIGKILL)
                    logger.warning(f"Killed stale process with PID {pid} found in {os.path.basename(pid_file)}.")
                except Exception as e:
                    logger.warning(f"Could not kill stale PID {pid}: {e}")
            else:
                logger.info(f"PID {pid} does not match expected script; leaving it alone.")
        except Exception:
            pass
        try:
            os.remove(pid_file)
        except Exception:
            pass

    try:
        # Default interpreter is the one running this script (the VENV interpreter)
        if interpreter is None:
            interpreter = sys.executable
            
        cmd = [interpreter, "-u", script_path]
        process = subprocess.Popen(cmd,
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT,
                                   preexec_fn=os.setsid)
        with open(pid_file, 'w') as f:
            f.write(str(process.pid))
        logger.info(f"[ACTIVATED] Process {os.path.basename(script_path)} started (PID: {process.pid}) using interpreter: {interpreter}")
        return process
    except Exception as e:
        logger.fatal(f"Could not start {os.path.basename(script_path)}: {e}")
        traceback.print_exc(file=sys.stdout)
        return None


def stop_process(process, pid_file):
    """
    Stops a running subprocess by sending SIGTERM/SIGKILL and cleans up the PID file.
    """
    if not process and not os.path.exists(pid_file):
        return True

    pid = process.pid if process else None
    if not pid and os.path.exists(pid_file):
        try:
            with open(pid_file, 'r') as f:
                pid = int(f.read().strip())
        except Exception:
            pid = None

    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(1)
            still_running = False
            if process:
                if process.poll() is None:
                    still_running = True
            else:
                still_running = os.path.exists(f"/proc/{pid}")

            if still_running:
                try:
                    os.kill(pid, signal.SIGKILL)
                except Exception:
                    pass

            logger.info(f"[DEACTIVATED] Process (PID: {pid}) stopped.")
        except OSError as e:
            if getattr(e, 'errno', None) == 3:  # ESRCH
                logger.info(f"Process {pid} was already dead. Cleaning up PID file.")
            else:
                logger.error(f"ERROR stopping process {pid}: {e}")
                return False

    if os.path.exists(pid_file):
        try:
            os.remove(pid_file)
        except Exception as e:
            logger.error(f"Could not remove PID file {os.path.basename(pid_file)}: {e}")
            return False

    return True


def read_process_output(process):
    """Non-blocking read of a subprocess stdout. Returns a single line or None."""
    if not process or not process.stdout:
        return None
    fd = process.stdout.fileno()
    try:
        rlist, _, _ = select.select([fd], [], [], 0)
        if rlist:
            raw = process.stdout.readline()
            if raw:
                return raw.decode(errors='ignore').rstrip()
    except Exception:
        return None
    return None


# --- Process Control Wrappers ---

def start_camera_server():
    global camera_server_process, current_streaming_enabled_state
    # Explicitly use the VENV interpreter (sys.executable)
    camera_server_process = start_process(CAMERA_SERVER_SCRIPT, CAMERA_SERVER_PID_FILE, interpreter=sys.executable)
    if camera_server_process:
        current_streaming_enabled_state = True


def stop_camera_server():
    global camera_server_process, current_streaming_enabled_state
    if stop_process(camera_server_process, CAMERA_SERVER_PID_FILE):
        camera_server_process = None
        current_streaming_enabled_state = False


def start_config_updater():
    global config_updater_process, current_app_open_state
    # This already defaults to sys.executable
    config_updater_process = start_process(SYSTEM_UPDATER_SCRIPT, SYSTEM_UPDATER_PID_FILE)
    if config_updater_process:
        current_app_open_state = True


def stop_config_updater():
    global config_updater_process, current_app_open_state
    if stop_process(config_updater_process, SYSTEM_UPDATER_PID_FILE):
        config_updater_process = None
        current_app_open_state = False


def start_motion_capture():
    global motion_capture_process, current_motion_capture_enabled_state
    # Explicitly use the VENV interpreter (sys.executable)
    motion_capture_process = start_process(MOTION_CAPTURE_SCRIPT, MOTION_CAPTURE_PID_FILE, interpreter=sys.executable)
    if motion_capture_process:
        current_motion_capture_enabled_state = True


def stop_motion_capture():
    global motion_capture_process, current_motion_capture_enabled_state
    if stop_process(motion_capture_process, MOTION_CAPTURE_PID_FILE):
        motion_capture_process = None
        current_motion_capture_enabled_state = False


# --- Firebase and Listener ---

def init_firebase():
    """Initializes Firebase Admin SDK and sets up the Firestore client."""
    global db
    if not os.path.exists(SERVICE_ACCOUNT_PATH):
        logger.fatal(f"Service Account file not found at {SERVICE_ACCOUNT_PATH}")
        return False

    try:
        cred = credentials.Certificate(SERVICE_ACCOUNT_PATH)
        app_name = 'master_control_app'
        try:
            app_instance = firebase_admin.get_app(app_name)
        except ValueError:
            app_instance = firebase_admin.initialize_app(cred, {
                'projectId': FIREBASE_PROJECT_ID
            }, name=app_name)

        db = firestore.client(app_instance)
        logger.info("Firebase initialized. Monitoring status documents.")
        return True
    except Exception as e:
        logger.fatal(f"Firebase initialization failed in Master Listener: {e}")
        traceback.print_exc(file=sys.stdout)
        return False


def on_doc_snapshot(doc_snapshot, changes, read_time):
    """Callback function when a monitored document changes."""
    if not doc_snapshot:
        return

    # FIX: Declare the global variable at the top of the function
    global motion_capture_paused_by_stream 

    for doc in doc_snapshot:
        doc_path = doc.reference.path
        doc_data = doc.to_dict() or {}
        
        # --- Handle STREAMING_STATUS_PATH ---
        if doc_path == STREAMING_STATUS_PATH:
            streaming_enabled = doc_data.get('enabled', False)

            # --- Stream Activation Logic ---
            if streaming_enabled and not current_streaming_enabled_state:
                logger.info(f"[{datetime.now().strftime('%H:%M:%S')}] STREAMING_ENABLED: Cloud TRUE. Preparing to activate Camera Server...")

                # 1. MUTUAL EXCLUSION: Check and stop Motion Capture if it's currently running
                if current_motion_capture_enabled_state:
                    logger.warning("Conflict detected: Motion Capture is running. Temporarily deactivating it for stream.")
                    stop_motion_capture()
                    # Track that we paused it so we can restart it later
                    motion_capture_paused_by_stream = True 
                else:
                    motion_capture_paused_by_stream = False
                
                # 2. Start Camera Server
                start_camera_server()
                
            # --- Stream Deactivation Logic ---
            elif not streaming_enabled and current_streaming_enabled_state:
                logger.info(f"[{datetime.now().strftime('%H:%M:%S')}] STREAMING_ENABLED: Cloud FALSE. Deactivating Camera Server...")
                
                # 1. Stop Camera Server
                stop_camera_server()

                # 2. MUTUAL EXCLUSION: Check if Motion Capture needs to be restarted
                if motion_capture_paused_by_stream:
                    logger.info("Camera Server stopped. Re-activating Motion Capture (was paused by stream request).")
                    start_motion_capture()
                    motion_capture_paused_by_stream = False # Reset the flag
                
        # --- Handle APP_OPEN_STATUS_PATH ---
        elif doc_path == APP_OPEN_STATUS_PATH:
            app_is_open = doc_data.get('open', False)
            if app_is_open and not current_app_open_state:
                logger.info(f"[{datetime.now().strftime('%H:%M:%S')}] APP_OPEN: Cloud TRUE. Activating Config Updater...")
                start_config_updater()
            elif not app_is_open and current_app_open_state:
                logger.info(f"[{datetime.now().strftime('%H:%M:%S')}] APP_OPEN: Cloud FALSE. Deactivating Config Updater...")
                stop_config_updater()

        # --- Handle CONFIG_SETTINGS_PATH ---
        elif doc_path == CONFIG_SETTINGS_PATH:
            motion_capture_enabled = doc_data.get('motion_capture_enabled', False)
            
            if motion_capture_enabled and not current_motion_capture_enabled_state:
                # Safety Check: Do not allow Motion Capture to start if streaming is active.
                if current_streaming_enabled_state:
                    logger.warning("Motion Capture is enabled in settings, but cannot start: Camera Server is active. Will start when stream ends.")
                    return # Exit the snapshot handler for this change
                    
                logger.info(f"[{datetime.now().strftime('%H:%M:%S')}] MOTION_CAPTURE_ENABLED: Settings TRUE. Activating Motion Capture Script...")
                start_motion_capture()
            elif not motion_capture_enabled and current_motion_capture_enabled_state:
                logger.info(f"[{datetime.now().strftime('%H:%M:%S')}] MOTION_CAPTURE_ENABLED: Settings FALSE. Deactivating Motion Capture Script...")
                # If motion capture is explicitly disabled in settings, clear the paused flag 
                # just in case it was pending a restart (though the streaming logic handles this primarily)
                motion_capture_paused_by_stream = False 
                stop_motion_capture()
            else:
                # Log state changes only, ignore when state is the same
                pass


def signal_handler(sig, frame):
    logger.info("Master Listener stopped by user.")
    stop_camera_server()
    stop_config_updater()
    stop_motion_capture()
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_handler)

    if not init_firebase():
        sys.exit(1)

    last_heartbeat_time = 0
    HEARTBEAT_INTERVAL = 30

    # Ensure all servers are stopped on start-up
    stop_camera_server()
    stop_config_updater()
    stop_motion_capture()

    stream_ref = db.document(STREAMING_STATUS_PATH)
    app_open_ref = db.document(APP_OPEN_STATUS_PATH)
    settings_ref = db.document(CONFIG_SETTINGS_PATH)

    try:
        stream_watch = stream_ref.on_snapshot(on_doc_snapshot)
        app_open_watch = app_open_ref.on_snapshot(on_doc_snapshot)
        settings_watch = settings_ref.on_snapshot(on_doc_snapshot)

        logger.info("Master Control Listener running. Monitoring status and config flags.")

        while True:
            current_time = time.time()
            if current_time - last_heartbeat_time > HEARTBEAT_INTERVAL:
                try:
                    current_ip = get_ip_address()
                    # Update the heartbeat document
                    db.collection('status').document('heartbeat').set({
                        'last_seen': firestore.SERVER_TIMESTAMP,
                        'ip_address': current_ip,
                        'status': 'online'
                    }, merge=True)
                    last_heartbeat_time = current_time
                    logger.info("[HEARTBEAT] Pulse sent. Current IP: {current_ip}")
                except Exception as e:
                    logger.warning(f"[HEARTBEAT] Failed to send pulse: {e}")
                    
            # Polling and logging subprocess output
            if camera_server_process:
                output = read_process_output(camera_server_process)
                if output:
                    logger.info(f"[CAMERA SERVER OUTPUT] {output}")

            if config_updater_process:
                output = read_process_output(config_updater_process)
                if output:
                    logger.info(f"[CONFIG_UPDATER OUTPUT] {output}")
            
            if motion_capture_process:
                output = read_process_output(motion_capture_process)
                if output:
                    logger.info(f"[MOTION_CAPTURE OUTPUT] {output}")

            time.sleep(0.1)

    except Exception as e:
        logger.fatal(f"FATAL ERROR during listener setup or main loop: {e}")
        traceback.print_exc(file=sys.stdout)

    finally:
        # Unsubscribe all listeners on exit
        if 'stream_watch' in locals():
            try: stream_watch.unsubscribe()
            except Exception: pass
        if 'app_open_watch' in locals():
            try: app_open_watch.unsubscribe()
            except Exception: pass
        if 'settings_watch' in locals():
            try: settings_watch.unsubscribe()
            except Exception: pass

        stop_camera_server()
        stop_config_updater()
        stop_motion_capture()
        logger.info("Master Control Listener process finished.")