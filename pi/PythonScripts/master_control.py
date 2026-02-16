# -*- coding: utf-8 -*-
"""
MASTER CONTROL LISTENER (Always On, Low Power)

Monitors Firestore status documents and manages lifecycle of child processes:
- camera_server.py (when streaming_enabled = true)
- system_updater.py (when app_is_open = true)
- motion_capture.py (when motion_capture_enabled = true)

MUTUAL EXCLUSION: Camera server and motion capture cannot run simultaneously
(camera hardware conflict). Streaming takes priority and pauses motion capture.

CRASH DETECTION: Monitors child processes and automatically restarts them if they crash.
"""

import os
import sys
import signal
import time
import subprocess
import traceback
import select
from datetime import datetime

# Import shared configuration
import shared_config as config

# Firebase Admin SDK imports
try:
    import firebase_admin
    from firebase_admin import firestore
except ImportError:
    print("FATAL: Firebase Admin SDK not found. Install: pip install firebase-admin")
    sys.exit(1)

# Setup logging
logger = config.setup_logging("master_control")

# Global Firebase client
db = None

# Process tracking
camera_server_process = None
system_updater_process = None
motion_capture_process = None

# State tracking
current_streaming_enabled = False
current_app_open = False
current_motion_capture_enabled = False
motion_capture_paused_by_stream = False


# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

def get_ip_address():
    """Get primary local IP address using hostname -I."""
    try:
        output = subprocess.check_output(['hostname', '-I']).decode('utf-8').strip()
        return output.split()[0] if output else '127.0.0.1'
    except Exception as e:
        logger.warning(f"Could not determine IP: {e}")
        return '127.0.0.1'


def pid_matches_script(pid: int, script_path: str) -> bool:
    """
    Verify that a PID corresponds to the expected script.

    Args:
        pid: Process ID to check
        script_path: Expected script path

    Returns:
        True if PID's command line contains the script path
    """
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmdline = f.read().decode(errors='ignore')
            return script_path in cmdline or os.path.basename(script_path) in cmdline
    except Exception:
        return False


def is_process_alive(process):
    """Check if a subprocess is still running."""
    if process is None:
        return False
    return process.poll() is None


def read_process_output(process):
    """Non-blocking read of subprocess stdout."""
    if not process or not process.stdout:
        return None

    try:
        fd = process.stdout.fileno()
        rlist, _, _ = select.select([fd], [], [], 0)
        if rlist:
            raw = process.stdout.readline()
            if raw:
                return raw.decode(errors='ignore').rstrip()
    except Exception:
        pass
    return None


# ============================================================================
# PROCESS LIFECYCLE MANAGEMENT
# ============================================================================

def start_process(script_path, pid_file, interpreter=None):
    """
    Start a Python script as a background process.

    Args:
        script_path: Path to Python script to execute
        pid_file: Path to PID file for tracking
        interpreter: Python interpreter to use (default: sys.executable)

    Returns:
        subprocess.Popen object or None on failure
    """
    # Clean up stale PID file if exists
    if os.path.exists(pid_file):
        logger.warning(f"PID file exists: {os.path.basename(pid_file)}, cleaning up")
        try:
            with open(pid_file, 'r') as f:
                old_pid = int(f.read().strip())
            if pid_matches_script(old_pid, script_path):
                try:
                    os.kill(old_pid, signal.SIGKILL)
                    logger.warning(f"Killed stale process PID {old_pid}")
                except Exception as e:
                    logger.warning(f"Could not kill stale PID {old_pid}: {e}")
            else:
                logger.info(f"PID {old_pid} does not match expected script")
        except Exception:
            pass

        try:
            os.remove(pid_file)
        except Exception:
            pass

    try:
        # Use VENV interpreter by default
        if interpreter is None:
            interpreter = sys.executable

        cmd = [interpreter, "-u", script_path]
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            preexec_fn=os.setsid
        )

        # Write PID file
        with open(pid_file, 'w') as f:
            f.write(str(process.pid))

        logger.info(f"[START] {os.path.basename(script_path)} (PID: {process.pid})")
        return process

    except Exception as e:
        logger.error(f"Failed to start {os.path.basename(script_path)}: {e}")
        traceback.print_exc()
        return None


def stop_process(process, pid_file):
    """
    Stop a running subprocess and clean up PID file.

    Args:
        process: subprocess.Popen object
        pid_file: Path to PID file

    Returns:
        True if successful, False otherwise
    """
    if not process and not os.path.exists(pid_file):
        return True

    # Get PID
    pid = process.pid if process else None
    if not pid and os.path.exists(pid_file):
        try:
            with open(pid_file, 'r') as f:
                pid = int(f.read().strip())
        except Exception:
            pid = None

    # Try graceful shutdown first (SIGTERM)
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(1)

            # Check if still running
            still_running = False
            if process:
                still_running = process.poll() is None
            else:
                still_running = os.path.exists(f"/proc/{pid}")

            # Force kill if needed (SIGKILL)
            if still_running:
                try:
                    os.kill(pid, signal.SIGKILL)
                except Exception:
                    pass

            logger.info(f"[STOP] Process PID {pid}")

        except OSError as e:
            if getattr(e, 'errno', None) == 3:  # ESRCH (no such process)
                logger.info(f"Process {pid} already dead, cleaning up PID file")
            else:
                logger.error(f"Error stopping process {pid}: {e}")
                return False

    # Remove PID file
    if os.path.exists(pid_file):
        try:
            os.remove(pid_file)
        except Exception as e:
            logger.error(f"Could not remove PID file {os.path.basename(pid_file)}: {e}")
            return False

    return True


# ============================================================================
# PROCESS-SPECIFIC WRAPPERS
# ============================================================================

def start_camera_server():
    """Start camera server process."""
    global camera_server_process, current_streaming_enabled
    camera_server_process = start_process(
        config.CAMERA_SERVER_SCRIPT,
        config.CAMERA_SERVER_PID_FILE,
        interpreter=sys.executable
    )
    if camera_server_process:
        current_streaming_enabled = True


def stop_camera_server():
    """Stop camera server process."""
    global camera_server_process, current_streaming_enabled
    if stop_process(camera_server_process, config.CAMERA_SERVER_PID_FILE):
        camera_server_process = None
        current_streaming_enabled = False


def start_system_updater():
    """Start system updater process."""
    global system_updater_process, current_app_open
    system_updater_process = start_process(
        config.SYSTEM_UPDATER_SCRIPT,
        config.SYSTEM_UPDATER_PID_FILE
    )
    if system_updater_process:
        current_app_open = True


def stop_system_updater():
    """Stop system updater process."""
    global system_updater_process, current_app_open
    if stop_process(system_updater_process, config.SYSTEM_UPDATER_PID_FILE):
        system_updater_process = None
        current_app_open = False


def start_motion_capture():
    """Start motion capture process."""
    global motion_capture_process, current_motion_capture_enabled
    motion_capture_process = start_process(
        config.MOTION_CAPTURE_SCRIPT,
        config.MOTION_CAPTURE_PID_FILE,
        interpreter=sys.executable
    )
    if motion_capture_process:
        current_motion_capture_enabled = True


def stop_motion_capture():
    """Stop motion capture process."""
    global motion_capture_process, current_motion_capture_enabled
    if stop_process(motion_capture_process, config.MOTION_CAPTURE_PID_FILE):
        motion_capture_process = None
        current_motion_capture_enabled = False


# ============================================================================
# CRASH DETECTION & AUTO-RESTART
# ============================================================================

def check_processes():
    """
    Check if child processes are still alive and restart if crashed.
    Called periodically from main loop.
    """
    global camera_server_process, system_updater_process, motion_capture_process

    # Check camera server
    if current_streaming_enabled and not is_process_alive(camera_server_process):
        logger.error("Camera server crashed! Restarting...")
        start_camera_server()

    # Check system updater
    if current_app_open and not is_process_alive(system_updater_process):
        logger.error("System updater crashed! Restarting...")
        start_system_updater()

    # Check motion capture
    if current_motion_capture_enabled and not is_process_alive(motion_capture_process):
        # Only restart if not paused by streaming
        if not motion_capture_paused_by_stream:
            logger.error("Motion capture crashed! Restarting...")
            start_motion_capture()


# ============================================================================
# FIREBASE INITIALIZATION
# ============================================================================

def init_firebase():
    """Initialize Firebase Admin SDK."""
    global db
    try:
        db, _ = config.init_firebase(
            app_name='master_control_app',
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
# FIRESTORE LISTENERS
# ============================================================================

def on_doc_snapshot(doc_snapshot, changes, read_time):
    """
    Callback when monitored Firestore documents change.
    Handles state changes for streaming, app open, and motion capture.
    """
    global motion_capture_paused_by_stream

    if not doc_snapshot:
        return

    for doc in doc_snapshot:
        doc_path = doc.reference.path
        doc_data = doc.to_dict() or {}

        # --- STREAMING STATUS ---
        if doc_path == config.STREAMING_STATUS_PATH:
            streaming_enabled = doc_data.get('enabled', False)

            # Stream activated
            if streaming_enabled and not current_streaming_enabled:
                logger.info("Streaming enabled - starting camera server")

                # Stop motion capture if running (mutual exclusion)
                if current_motion_capture_enabled:
                    logger.warning("Stopping motion capture for streaming (camera conflict)")
                    stop_motion_capture()
                    motion_capture_paused_by_stream = True
                else:
                    motion_capture_paused_by_stream = False

                start_camera_server()

            # Stream deactivated
            elif not streaming_enabled and current_streaming_enabled:
                logger.info("Streaming disabled - stopping camera server")
                stop_camera_server()

                # Restart motion capture if it was paused
                if motion_capture_paused_by_stream:
                    logger.info("Restarting motion capture (was paused by streaming)")
                    start_motion_capture()
                    motion_capture_paused_by_stream = False

        # --- APP OPEN STATUS ---
        elif doc_path == config.APP_OPEN_STATUS_PATH:
            app_is_open = doc_data.get('open', False)

            if app_is_open and not current_app_open:
                logger.info("App opened - starting system updater")
                start_system_updater()
            elif not app_is_open and current_app_open:
                logger.info("App closed - stopping system updater")
                stop_system_updater()

        # --- MOTION CAPTURE SETTINGS ---
        elif doc_path == config.CONFIG_SETTINGS_PATH:
            motion_enabled = doc_data.get('motion_capture_enabled', False)

            if motion_enabled and not current_motion_capture_enabled:
                # Don't start if streaming is active
                if current_streaming_enabled:
                    logger.warning("Motion capture enabled but streaming active - will start when streaming stops")
                    return

                logger.info("Motion capture enabled - starting motion capture")
                start_motion_capture()

            elif not motion_enabled and current_motion_capture_enabled:
                logger.info("Motion capture disabled - stopping motion capture")
                motion_capture_paused_by_stream = False
                stop_motion_capture()


# ============================================================================
# SIGNAL HANDLING
# ============================================================================

def signal_handler(sig, frame):
    """Handle shutdown signals gracefully."""
    logger.info("Shutdown signal received")
    stop_camera_server()
    stop_system_updater()
    stop_motion_capture()
    sys.exit(0)


# ============================================================================
# MAIN EXECUTION
# ============================================================================

if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Initialize Firebase
    if not init_firebase():
        logger.error("Exiting due to Firebase initialization failure")
        sys.exit(1)

    # Ensure all processes are stopped on startup
    logger.info("Ensuring clean startup - stopping any running processes")
    stop_camera_server()
    stop_system_updater()
    stop_motion_capture()

    # Setup Firestore listeners
    stream_ref = db.document(config.STREAMING_STATUS_PATH)
    app_open_ref = db.document(config.APP_OPEN_STATUS_PATH)
    settings_ref = db.document(config.CONFIG_SETTINGS_PATH)

    try:
        stream_watch = stream_ref.on_snapshot(on_doc_snapshot)
        app_open_watch = app_open_ref.on_snapshot(on_doc_snapshot)
        settings_watch = settings_ref.on_snapshot(on_doc_snapshot)

        logger.info("Master Control Listener active - monitoring Firestore")
        logger.info(f"Heartbeat interval: {config.HEARTBEAT_INTERVAL}s")
        logger.info("-" * 60)

        last_heartbeat_time = 0
        last_process_check_time = 0
        PROCESS_CHECK_INTERVAL = 5  # Check for crashes every 5 seconds

        # Main loop
        while True:
            current_time = time.time()

            # Send heartbeat
            if current_time - last_heartbeat_time > config.HEARTBEAT_INTERVAL:
                try:
                    current_ip = get_ip_address()
                    db.collection('status').document('heartbeat').set({
                        'last_seen': firestore.SERVER_TIMESTAMP,
                        'ip_address': current_ip,
                        'status': 'online'
                    }, merge=True)
                    last_heartbeat_time = current_time
                    logger.info(f"[HEARTBEAT] Sent - IP: {current_ip}")
                except Exception as e:
                    logger.warning(f"[HEARTBEAT] Failed: {e}")

            # Check for crashed processes
            if current_time - last_process_check_time > PROCESS_CHECK_INTERVAL:
                check_processes()
                last_process_check_time = current_time

            # Log subprocess output
            for process, name in [
                (camera_server_process, "CAMERA"),
                (system_updater_process, "UPDATER"),
                (motion_capture_process, "MOTION")
            ]:
                if process:
                    output = read_process_output(process)
                    if output:
                        logger.info(f"[{name}] {output}")

            time.sleep(0.1)

    except Exception as e:
        logger.error(f"Fatal error in main loop: {e}")
        traceback.print_exc()

    finally:
        # Unsubscribe from Firestore listeners
        if 'stream_watch' in locals():
            try:
                stream_watch.unsubscribe()
            except Exception:
                pass
        if 'app_open_watch' in locals():
            try:
                app_open_watch.unsubscribe()
            except Exception:
                pass
        if 'settings_watch' in locals():
            try:
                settings_watch.unsubscribe()
            except Exception:
                pass

        # Stop all child processes
        stop_camera_server()
        stop_system_updater()
        stop_motion_capture()

        logger.info("Master Control Listener shutdown complete")
