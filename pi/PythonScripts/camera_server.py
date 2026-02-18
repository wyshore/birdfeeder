# -*- coding: utf-8 -*-
"""
CAMERA SERVER - TCP JPEG Streaming + Snapshot Upload

Provides:
1. Low-res hardware-encoded JPEG stream (lores) for live viewing
2. High-res snapshot capture (main stream) with Firebase upload

Protocol:
- Stream: [4 bytes len little-endian][JPEG bytes]
- Snapshot command: 0x01 0x01 -> server uploads snapshot and replies 'S' or 'F'

Uses select module for robust, non-blocking command reading.
"""

import io
import socket
import struct
import threading
import signal
import time
import sys
import traceback
import select
import os
import json
from datetime import datetime
from threading import Condition, Lock, Event

# Import shared configuration
import shared_config as config

# Setup logging
log = config.setup_logging("camera_server")

# Camera imports
try:
    from picamera2 import Picamera2
    from picamera2.encoders import JpegEncoder
    from picamera2.outputs import FileOutput
except ImportError:
    log.error("Missing picamera2. Install: pip3 install picamera2")
    sys.exit(1)

# Firebase imports
try:
    from firebase_admin import storage, firestore
    HAVE_FIREBASE = True
except ImportError:
    HAVE_FIREBASE = False
    log.warning("Firebase SDK not found. Snapshots will not upload.")


# ============================================================================
# CONFIGURATION
# ============================================================================

# ============================================================================
# CONFIGURATION
# ============================================================================

def load_camera_settings():
    """
    Load camera resolution, framerate, and controls from local config file.
    Falls back to defaults if file is missing or invalid.

    Returns:
        tuple: (stream_res, snapshot_res, framerate, camera_controls)
    """
    stream_res = config.DEFAULT_STREAM_RESOLUTION
    snapshot_res = config.DEFAULT_SNAPSHOT_RESOLUTION
    framerate = config.DEFAULT_FRAMERATE
    controls = dict(config.DEFAULT_CAMERA_CONTROLS)

    if os.path.exists(config.LOCAL_CONFIG_FILE):
        try:
            with open(config.LOCAL_CONFIG_FILE, 'r') as f:
                settings = json.load(f)

            # Stream resolution
            res = settings.get("stream_resolution")
            if isinstance(res, (list, tuple)) and len(res) >= 2:
                stream_res = (int(res[0]), int(res[1]))

            # Snapshot resolution
            snap = settings.get("snapshot_resolution")
            if isinstance(snap, (list, tuple)) and len(snap) >= 2:
                snapshot_res = (int(snap[0]), int(snap[1]))

            # Framerate
            fps = settings.get("stream_framerate")
            if isinstance(fps, int):
                framerate = fps

            # Camera controls
            saved_controls = settings.get("camera_controls")
            if isinstance(saved_controls, dict):
                controls.update(saved_controls)

        except Exception as e:
            log.warning(f"Could not load local config, using defaults: {e}")

    return stream_res, snapshot_res, framerate, controls


SERVER_ADDRESS = config.CAMERA_SERVER_ADDRESS
SERVER_PORT = config.CAMERA_SERVER_PORT

# Default values — will be overridden by load_camera_settings() in Streamer.start_camera()
STREAM_RES = config.DEFAULT_STREAM_RESOLUTION
SNAPSHOT_RES = config.DEFAULT_SNAPSHOT_RESOLUTION
FRAME_RATE = config.DEFAULT_FRAMERATE

# Snapshot command protocol
CMD_PREFIX = b'\x01'
CMD_SNAPSHOT = b'\x01'
CMD_SIZE = 2


# ============================================================================
# GLOBAL LATEST FRAME HOLDER
# ============================================================================

class LatestFrame:
    """Thread-safe holder for the most recent JPEG frame."""

    def __init__(self):
        self.frame = None
        self.cond = Condition()

    def set(self, data: bytes):
        """Update frame and notify waiting threads."""
        with self.cond:
            self.frame = data
            self.cond.notify_all()

    def wait(self, timeout):
        """Wait for next frame update."""
        with self.cond:
            return self.cond.wait(timeout=timeout)

    def get(self):
        """Get current frame."""
        return self.frame


latest = LatestFrame()


# ============================================================================
# STREAMER CLASS
# ============================================================================

class Streamer:
    """Main streaming server with Firebase snapshot upload capability."""

    def __init__(self):
        self.picam2 = None
        self.running = True
        self.server_socket = None
        self.bucket = None
        self.db = None
        self.camera_lock = Lock()

    def init_firebase(self):
        """Initialize Firebase services."""
        if not HAVE_FIREBASE:
            log.warning("Firebase SDK not available - snapshots disabled")
            return

        try:
            self.db, self.bucket = config.init_firebase(
                app_name='camera_server_app',
                require_firestore=True,
                require_storage=True
            )
            log.info("Firebase connected")
        except Exception as e:
            log.error(f"Firebase initialization failed: {e}")
            traceback.print_exc()

    def upload_snapshot(self, data: bytes, size_bytes: int, timestamp: str):
        """Upload snapshot to Firebase Storage and log metadata."""
        if not self.bucket:
            log.warning("Firebase not initialized - skipping upload")
            return

        try:
            # Generate filename
            filename = config.get_timestamp_filename(prefix="snapshot", extension="jpg")
            storage_path = f"{config.SNAPSHOTS_STORAGE_PATH}/{filename}"

            # Upload to Storage
            blob = self.bucket.blob(storage_path)
            blob.upload_from_string(data, content_type='image/jpeg', timeout=30)
            blob.make_public()
            image_url = blob.public_url
            log.info(f"Uploaded snapshot: {storage_path}")

            # Log metadata to Firestore
            self.db.collection("logs").document("snapshots").collection("data").add({
                "imageUrl": image_url,
                "resolution": f"{SNAPSHOT_RES[0]}x{SNAPSHOT_RES[1]}",
                "sizeBytes": size_bytes,
                "storagePath": storage_path,
                "timestamp": timestamp,
                "isIdentified": False,
                "catalogBirdId": "",
                "speciesName": "",
            })
            log.info("Snapshot metadata logged to Firestore")

        except Exception as e:
            log.error(f"Snapshot upload failed: {e}")
            traceback.print_exc()

    def send_packet(self, conn, payload: bytes):
        """Send payload with 4-byte length prefix."""
        size_prefix = struct.pack('<L', len(payload))
        conn.sendall(size_prefix)
        conn.sendall(payload)

    def start_camera(self):
        """Start camera with hardware JPEG encoding."""
        global STREAM_RES, SNAPSHOT_RES, FRAME_RATE
        
        # Load camera settings (only when actually needed)
        stream_res, snapshot_res, framerate, camera_controls = load_camera_settings()
        STREAM_RES = stream_res
        SNAPSHOT_RES = snapshot_res
        FRAME_RATE = framerate
        log.info(f"Camera settings loaded: stream={STREAM_RES}, snapshot={SNAPSHOT_RES}, fps={FRAME_RATE}")
        
        self.picam2 = Picamera2()

        # Configure dual streams
        cfg = self.picam2.create_video_configuration(
            main={"size": SNAPSHOT_RES},  # High-res for snapshots
            lores={"size": STREAM_RES, "format": "YUV420"},  # Low-res for streaming
            queue=False,
            encode="lores"
        )
        self.picam2.configure(cfg)

        # Apply camera controls (sharpness, contrast, exposure, etc.)
        all_controls = dict(camera_controls)
        all_controls['FrameRate'] = FRAME_RATE
        try:
            self.picam2.set_controls(all_controls)
            log.info(f"Camera controls applied: {all_controls}")
        except Exception as e:
            log.warning(f"Some camera controls failed to apply: {e}")
            # Fall back to just framerate
            self.picam2.set_controls({'FrameRate': FRAME_RATE})

        # Frame writer for encoder output
        class FrameWriter(io.BufferedIOBase):
            def write(self_inner, buf: bytes):
                latest.set(buf)

        # Start hardware encoding
        output_wrapper = FileOutput(FrameWriter())
        self.picam2.start_recording(JpegEncoder(), output_wrapper, name='lores')
        log.info(f"Camera started - stream: {STREAM_RES}, snapshot: {SNAPSHOT_RES}, {FRAME_RATE}fps")

    def take_snapshot(self, conn):
        """Capture high-res snapshot and upload to Firebase."""
        ok = False

        with self.camera_lock:
            try:
                # Capture high-res frame
                bio = io.BytesIO()
                self.picam2.capture_file(bio, format='jpeg', name='main')
                data = bio.getvalue()
                size_bytes = len(data)

                if not data:
                    raise RuntimeError("Captured frame was empty")

                timestamp = config.get_timestamp_string()

                # Upload to Firebase
                if HAVE_FIREBASE:
                    self.upload_snapshot(data, size_bytes, timestamp)

                ok = True
                log.info("Snapshot captured and uploaded successfully")

            except Exception as e:
                log.error(f"Snapshot failed: {e}")
                log.error(traceback.format_exc())

        # Send confirmation to client
        try:
            self.send_packet(conn, b'S' if ok else b'F')
        except Exception:
            log.warning("Client disconnected before snapshot confirmation")

    def client_sender(self, conn, stop_event: Event, slot: dict):
        """Continuously send latest frames to client."""
        try:
            while not stop_event.is_set():
                # Wait for new frame
                if not slot['event'].wait(timeout=0.5):
                    continue
                slot['event'].clear()

                # Get frame from slot
                with slot['lock']:
                    frame = slot.get('frame')
                    slot['frame'] = None

                if not frame:
                    continue

                # Send frame
                try:
                    self.send_packet(conn, frame)
                except (socket.error, BrokenPipeError, ConnectionResetError, OSError) as e:
                    log.warning(f"Sender network error: {e}")
                    break

        finally:
            try:
                conn.close()
            except:
                pass
            log.info("Client sender thread finished")

    def handle_client(self, conn, addr):
        """Handle client connection - send frames and process commands."""
        log.info(f"Client {addr} connected")

        # Setup sender thread
        slot = {'frame': None, 'lock': Lock(), 'event': Event()}
        stop_event = threading.Event()
        sender = threading.Thread(
            target=self.client_sender,
            args=(conn, stop_event, slot),
            daemon=True
        )
        sender.start()

        read_buf = b''
        timeout_s = 0.01

        try:
            while self.running:
                # Check for incoming commands (non-blocking)
                rlist, _, _ = select.select([conn], [], [], timeout_s)

                if rlist:
                    # Data available to read
                    try:
                        data = conn.recv(CMD_SIZE)
                        if not data:
                            break  # Client disconnected

                        read_buf += data

                        # Process commands in buffer
                        while len(read_buf) >= CMD_SIZE:
                            cmd = read_buf[:CMD_SIZE]
                            read_buf = read_buf[CMD_SIZE:]

                            if cmd == CMD_PREFIX + CMD_SNAPSHOT:
                                log.info(f"Snapshot command received from {addr}")
                                threading.Thread(
                                    target=self.take_snapshot,
                                    args=(conn,),
                                    daemon=True
                                ).start()
                            else:
                                log.warning(f"Unknown command {cmd.hex()} from {addr}")
                                read_buf = b''  # Clear buffer on junk

                    except socket.error as e:
                        log.warning(f"Client {addr} socket error: {e}")
                        break

                # Wait for new frame
                if not latest.wait(timeout=0.1):
                    continue

                # Place frame in sender slot
                frame = latest.get()
                if frame:
                    with slot['lock']:
                        slot['frame'] = frame
                        slot['event'].set()

        except Exception as e:
            log.error(f"Client {addr} handler exception: {e}")
            log.error(traceback.format_exc())

        finally:
            stop_event.set()
            slot['event'].set()
            sender.join(timeout=1.0)
            try:
                conn.close()
            except:
                pass
            log.info(f"Client {addr} disconnected")

    def listen(self):
        """Accept incoming client connections."""
        self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_socket.bind((SERVER_ADDRESS, SERVER_PORT))
        self.server_socket.listen(5)

        host_ip = socket.gethostbyname(socket.gethostname())
        log.info(f"Listening on tcp://{host_ip}:{SERVER_PORT}")

        self.server_socket.settimeout(0.5)
        while self.running:
            try:
                conn, addr = self.server_socket.accept()
                threading.Thread(
                    target=self.handle_client,
                    args=(conn, addr),
                    daemon=True
                ).start()
            except socket.timeout:
                continue
            except Exception:
                if self.running:
                    log.warning("Listener error during accept")
                continue

    def serve(self):
        """Start the streaming server."""
        self.init_firebase()
        self.start_camera()

        # Start listener thread
        threading.Thread(target=self.listen, daemon=True).start()

        # Setup signal handlers
        signal.signal(signal.SIGINT, lambda *_: self.stop())
        signal.signal(signal.SIGTERM, lambda *_: self.stop())

        # Keep running
        while self.running:
            time.sleep(1)

    def stop(self):
        """Shutdown server gracefully."""
        if not self.running:
            return

        self.running = False

        try:
            if self.server_socket:
                self.server_socket.close()

            if self.picam2:
                try:
                    self.picam2.stop_recording()
                except:
                    pass
                try:
                    self.picam2.close()
                except:
                    pass
        except Exception:
            pass

        log.info("Server stopped")


# ============================================================================
# ENTRY POINT
# ============================================================================

if __name__ == "__main__":
    try:
        Streamer().serve()
    except Exception as e:
        log.critical(f"FATAL: {e}")
        log.critical(traceback.format_exc())
