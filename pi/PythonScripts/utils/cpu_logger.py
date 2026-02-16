import logging
import time
import psutil
import os
from datetime import datetime
from typing import Tuple

# --- CONFIGURATION ---
LOG_FILE_PATH = "/home/wyattshore/Birdfeeder/Logs/cpu_log.txt"
LOG_INTERVAL_SECONDS =  5 # Log every 5 seconds

# --- LOGGING SETUP ---

# 1. Configure the root logger to output to a file and the console
# The basicConfig MUST be called before any getLogger() calls if you want it to set up the handlers.
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE_PATH), # Log to a file
        logging.StreamHandler()             # Log to the console (stdout)
    ]
)

# 2. Get the logger instance (this is where the original error occurred)
log = logging.getLogger("cpu_monitor") 

# --- UTILITY FUNCTIONS ---

def get_cpu_data() -> Tuple[float, float, str]:
    """Retrieves CPU usage, temperature, and current load."""
    try:
        # Get overall CPU utilization percentage
        cpu_percent = psutil.cpu_percent(interval=1)
        
        # Get temperature (Raspberry Pi specific, often under 'cpu_thermal')
        temp = 0.0
        temp_label = "N/A"
        if hasattr(psutil, 'sensors_temperatures'):
            temps = psutil.sensors_temperatures()
            if 'cpu_thermal' in temps:
                temp = temps['cpu_thermal'][0].current
                temp_label = "cpu_thermal"
            elif 'coretemp' in temps:
                temp = temps['coretemp'][0].current
                temp_label = "coretemp"

        # Get system load average (1 minute)
        # os.getloadavg() returns (1 min, 5 min, 15 min)
        load_avg = os.getloadavg()[0] 
        
        return cpu_percent, temp, f"1min Load: {load_avg:.2f}"
    
    except Exception as e:
        log.error(f"Error reading system data: {e}")
        return 0.0, 0.0, "ERROR"

# --- MAIN LOGGING LOOP ---

def main_loop():
    log.info(f"CPU Monitor started. Logging to: {LOG_FILE_PATH}")
    log.info(f"Log interval set to {LOG_INTERVAL_SECONDS} seconds.")
    
    while True:
        cpu_usage, cpu_temp, cpu_load = get_cpu_data()
        
        if cpu_usage > 0.0: # Check if data was successfully read
            log_message = (
                f"CPU: {cpu_usage:0.1f}% | "
                f"Temp: {cpu_temp:0.1f}°C | "
                f"Load: {cpu_load}"
            )
            log.info(log_message)
        
        time.sleep(LOG_INTERVAL_SECONDS)

# ---------- ENTRY POINT ----------
if __name__ == "__main__":
    # Ensure psutil is available
    try:
        psutil.cpu_percent()
    except Exception:
        log.fatal("psutil is not installed. Please run: pip install psutil")
        exit(1)
        
    main_loop()