# -*- coding: utf-8 -*-
"""
Reliable hardware-encoded TCP JPEG streamer + snapshot upload (single camera).

Protocol:
- Stream: [4 bytes len little-endian][JPEG bytes]
- Snapshot command: 0x01 0x01 -> server uploads snapshot and replies 'S' or 'F'

*** FIX APPLIED: Using 'select' module for robust, non-blocking command reading. ***
This prevents the client handler from exiting due to non-data-related socket errors 
that occur when trying to read from an empty non-blocking buffer.
"""
import io, socket, struct, threading, signal, time, sys, logging
from datetime import datetime
from threading import Condition, Lock, Event
import traceback 
import select # Import the select module for robust polling

# ---------- CONFIG ----------
SERVER_ADDRESS, SERVER_PORT = '0.0.0.0', 8000
STREAM_RES, SNAPSHOT_RES, FRAME_RATE = (640,360), (2560, 1440), 10   # 16:9
CMD_PREFIX, CMD_SNAPSHOT, CMD_SIZE = b'\x01', b'\x01', 2
# NOTE: Ensure this path and bucket match your setup
SERVICE_ACCOUNT_PATH = '/home/wyattshore/Birdfeeder/birdfeeder-sa.json' 
STORAGE_BUCKET = 'birdfeeder-b6224.firebasestorage.app'
SNAPSHOT_PATH = 'media/snapshots'

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("tcp_cam")

# ---------- IMPORTS ----------
try:
    from picamera2 import Picamera2
    from picamera2.encoders import JpegEncoder
    from picamera2.outputs import FileOutput # REQUIRED FOR THE FIX
except ImportError:
    sys.exit("Missing picamera2. Install: pip3 install picamera2")

try:
    import firebase_admin
    from firebase_admin import credentials, storage, firestore
    HAVE_FIREBASE = True
except ImportError:
    HAVE_FIREBASE = False
    log.warning("Firebase SDK not found. Snapshots will not upload.")

# ---------- GLOBAL LATEST FRAME ----------
class LatestFrame:
    """Holds the latest low-res JPEG frame produced by the encoder."""
    def __init__(self):
        self.frame = None
        self.cond = Condition()
    def set(self, b: bytes):
        """Update frame and notify waiting sender threads."""
        with self.cond:
            self.frame = b
            self.cond.notify_all()
    def wait(self, timeout):
        with self.cond:
            # waits for notification that the frame has been updated
            return self.cond.wait(timeout=timeout)
    def get(self):
        return self.frame

latest = LatestFrame()

# ---------- STREAMER ----------
class Streamer:
    def __init__(self):
        self.picam2 = None
        self.running = True
        self.server_socket = None
        self.bucket = None
        self.db = None
        self.camera_lock = Lock()  

    # Firebase
    def init_firebase(self):
        if not HAVE_FIREBASE: return
        if not firebase_admin._apps:
            cred = credentials.Certificate(SERVICE_ACCOUNT_PATH)
            firebase_admin.initialize_app(cred, {'storageBucket': STORAGE_BUCKET})
        self.bucket = storage.bucket(STORAGE_BUCKET)
        self.db = firestore.client()
        log.info("Firebase connected")

    def upload_snapshot(self, data: bytes, size_bytes: int, timestamp: str):
        if not self.bucket: return
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        path = f"{SNAPSHOT_PATH}/snapshot_{ts}.jpg"
        blob = self.bucket.blob(path)

        # Set a timeout for the network operation
        blob.upload_from_string(data, content_type='image/jpeg', timeout=30)
        blob.make_public() #make image viewable
        image_url = blob.public_url
        log.info(f"Uploaded snapshot to storage: {path}")

        # 2. Firestore Logging
        self.db.collection("logs").document("snapshots").collection("data").add({
            "imageUrl": image_url, 
            "resolution": f"{SNAPSHOT_RES[0]}x{SNAPSHOT_RES[1]}", 
            "sizeBytes": size_bytes,
            "storagePath": path,
            "timestamp": timestamp, 
        })
        log.info(f"Logged metadata to Firestore: logs/snapshots/data")

    # Networking helpers
    def send_packet(self, conn, payload: bytes):
        """Sends a single payload following the [4 bytes len][payload] protocol."""
        size_prefix = struct.pack('<L', len(payload))
        conn.sendall(size_prefix)
        conn.sendall(payload)

    # Camera: start lores encoding -> hardware JpegEncoder
    def start_camera(self):
        self.picam2 = Picamera2()
        
        cfg = self.picam2.create_video_configuration(
            # Main stream running high-res for immediate, high-quality snapshot capture
            main={"size": SNAPSHOT_RES},
            # Lores stream running low-res YUV for efficient hardware JPEG encoding
            lores={"size": STREAM_RES, "format": "YUV420"},
            queue=False, encode="lores"
        )
        self.picam2.configure(cfg)
        self.picam2.set_controls({'FrameRate': FRAME_RATE})

        # FileOutput subclass: encoder thread will call write(buf)
        class FrameWriter(io.BufferedIOBase):
            def write(self_inner, buf: bytes):
                # called by encoder thread; keep fast: replace latest frame and notify
                latest.set(buf)

        # *** FIX IS HERE ***
        output_wrapper = FileOutput(FrameWriter())
        
        # Start recording, piping JPEG frames from LORES stream directly to our buffer
        self.picam2.start_recording(JpegEncoder(), output_wrapper, name='lores')
        log.info("Camera started with hardware JPEG encoder (lores)")

    # Snapshot: captures high-res frame, uploads to Firebase
    def take_snapshot(self, conn):
        """Runs in a separate thread. Captures high-res, uploads, and sends confirmation."""
        ok = False
        
        with self.camera_lock:
            try:
                # 1. Capture High-Res Frame from the running 'main' stream
                bio = io.BytesIO()
                # capture_file on the main stream for a high-res JPEG
                self.picam2.capture_file(bio, format='jpeg', name='main')
                data = bio.getvalue()
                size_bytes = len(data)
                now = datetime.now()
                timestamp = now.strftime("%Y-%m-%d %H:%M:%S")

                if not data:
                    raise RuntimeError("Captured snapshot frame was empty.")
                
                # 2. Upload to Firebase
                if HAVE_FIREBASE:
                    self.upload_snapshot(data, size_bytes, timestamp)
                
                ok = True
                log.info("Snapshot captured and uploaded successfully.")

            except Exception as e:
                log.error(f"Snapshot or upload failed: {e}")
                log.error(tracebox.format_exc())
        
        # 3. Send confirmation (client may have disconnected)
        try:
            # IMPORTANT: Confirmation packet is always [4 bytes len=1][S/F]
            self.send_packet(conn, b'S' if ok else b'F')
        except Exception:
            log.warning("Client disconnected before snapshot confirmation.")

    # Per-client sender thread (consumes single-slot buffer)
    def client_sender(self, conn, stop_event: Event, slot: dict):
        """Continuously pulls the latest frame from its slot and sends it."""
        try:
            while not stop_event.is_set():
                # Wait for a new frame, or timeout to check stop_event
                if not slot['event'].wait(timeout=0.5):
                    continue
                slot['event'].clear()
                
                with slot['lock']:
                    frame = slot.get('frame')
                    slot['frame'] = None
                
                if not frame:
                    continue
                
                # Send the frame
                try:
                    self.send_packet(conn, frame)
                # CRITICAL FIX: Gracefully handle network disconnects/slow clients
                except (socket.error, BrokenPipeError, ConnectionResetError, OSError) as e:
                    # Client abruptly closed the socket.
                    log.warning(f"Sender network error: {e}. Disconnecting client.")
                    # Trigger shutdown of the handler thread
                    break
        finally:
            try: conn.close()
            except: pass
            log.info("Client sender thread finished.")

    # Client handler: places newest frame into sender slot, reads commands
    def handle_client(self, conn, addr):
        log.info(f"Client {addr} connected")
        
        slot = {'frame': None, 'lock': Lock(), 'event': Event()}
        stop_event = threading.Event()
        # Use a non-daemon thread for the sender to ensure cleanup if main thread dies
        sender = threading.Thread(target=self.client_sender, args=(conn, stop_event, slot), daemon=True) 
        sender.start()
        
        read_buf = b''
        timeout_s = 0.01 # Polling delay for select
        
        try:
            while self.running:
                # 1. Check for incoming commands (non-blocking using select)
                # Check the connection (conn) for readability (rlist) with a short timeout
                rlist, _, _ = select.select([conn], [], [], timeout_s)
                
                if rlist:
                    # Data is available to read
                    try:
                        # Now we call recv, knowing it won't block indefinitely
                        data = conn.recv(CMD_SIZE)
                        if not data:
                            break # Client disconnected gracefully
                        read_buf += data
                        
                        # Process commands in the buffer
                        while len(read_buf) >= CMD_SIZE:
                            cmd = read_buf[:CMD_SIZE]
                            read_buf = read_buf[CMD_SIZE:]
                            
                            if cmd == CMD_PREFIX + CMD_SNAPSHOT:
                                log.info(f"Received Snapshot Command {cmd.hex()} from {addr}. Starting upload thread.")
                                # Pass the connection object to the snapshot thread
                                threading.Thread(target=self.take_snapshot, args=(conn,), daemon=True).start()
                            else:
                                log.warning(f"Unknown cmd {cmd.hex()} from {addr}. "
                                            "Ensure client sends raw 2-byte command (0x0101).")
                                # If we get junk, clear the buffer to avoid getting stuck
                                if len(read_buf) > 0:
                                    log.warning(f"Discarding {len(read_buf)} remaining bytes in read buffer.")
                                    read_buf = b''


                    except socket.error as e:
                        log.warning(f"Client {addr} socket read error: {e}. Closing connection.")
                        break # Critical read error, break the client handler loop
                
                # 2. Wait for a new latest frame to send
                # The timeout in latest.wait is essential to keep the loop responsive
                if not latest.wait(timeout=0.1): 
                    continue
                
                # 3. Place frame in sender slot
                frame = latest.get()
                if not frame:
                    continue
                    
                with slot['lock']:
                    slot['frame'] = frame 
                    slot['event'].set() # Tell the sender thread the slot is full
                    
        except Exception as e:
            log.critical(f"Client {addr} CRITICAL handler exception: {e}")
            log.error(traceback.format_exc())
            
        finally:
            stop_event.set() # Tells sender to stop
            slot['event'].set() # Wake up sender if waiting
            sender.join(timeout=1.0)
            # This close should safely happen after the sender finishes
            try: conn.close()
            except: pass
            log.info(f"Client {addr} disconnected")

    # Listener
    def listen(self):
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
                threading.Thread(target=self.handle_client, args=(conn, addr), daemon=True).start()
            except socket.timeout:
                continue
            except Exception:
                if self.running: log.warning("Listener error during accept.")
                continue

    def serve(self):
        self.init_firebase()
        self.start_camera()
        threading.Thread(target=self.listen, daemon=True).start()
        signal.signal(signal.SIGINT, lambda *_: self.stop())
        signal.signal(signal.SIGTERM, lambda *_: self.stop())
        while self.running:
            time.sleep(1)

    def stop(self):
        if not self.running:
            return
        self.running = False
        try:
            if self.server_socket: self.server_socket.close()
            if self.picam2:
                try: self.picam2.stop_recording()
                except: pass
                try: self.picam2.close()
                except: pass
        except Exception:
            pass
        log.info("Server stopped")

# ---------- ENTRY ----------
if __name__ == "__main__":
    try:
        Streamer().serve()
    except Exception as e:
        log.critical(f"FATAL: {e}")
        log.critical(traceback.format_exc())