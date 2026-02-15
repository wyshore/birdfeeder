# -*- coding: utf-8 -*-
import time
from datetime import datetime
import sys
import os

# --- Hardware Library Imports ---
try:
    # Use DigitalInputDevice, which has wait_for_active/inactive methods
    from gpiozero import DigitalInputDevice 
except ImportError:
    print("FATAL ERROR: gpiozero library not found. Please run: pip install gpiozero")
    sys.exit(1)


# --- Configuration ---
SENSOR_PIN = 4 
CSV_FILEPATH = "motion_test_uncovered.csv"
MIN_REAL_PULSE_DURATION = 6.5 # Seconds: Pulses shorter than this are considered noise spikes


# --- Helper Function for CSV Logging ---

def log_to_csv(timestamp, duration, status):
    """Appends the event data to the local CSV file."""
    
    # Check if file exists to write header if necessary
    file_exists = os.path.exists(CSV_FILEPATH)
    
    try:
        # Open file in append mode. If it doesn't exist, it will be created.
        with open(CSV_FILEPATH, 'a') as f:
            # Write header if the file was just created
            if not file_exists:
                f.write("Timestamp,Pulse Width (s),Status\n")
            
            # Write the data line
            f.write(f"{timestamp},{duration:.4f},{status}\n")
            
    except IOError as e:
        print(f"Warning: Could not write to CSV file: {e}")


# --- Pulse Monitoring Function ---

def monitor_pulse_width():
    """Initializes the GPIO pin and monitors the pulse width for diagnostics."""
    
    # Initialization using DigitalInputDevice with pull-down resistor
    # This ensures a clean LOW state when the sensor is inactive.
    try:
        pir_pin = DigitalInputDevice(SENSOR_PIN, pull_up=False) 
    except Exception as e:
        print(f"FATAL ERROR: GPIO initialization failed. Check wiring and privileges: {e}")
        sys.exit(1)
        
    print("-" * 50)
    print(f"** Motion Pulse Width Logger Active **")
    print(f"Logging to: {os.path.abspath(CSV_FILEPATH)}")
    print(f"Monitoring BCM Pin: {pir_pin.pin.number} (GPIO {SENSOR_PIN})")
    print(f"Noise Threshold: < {MIN_REAL_PULSE_DURATION} seconds")
    print("-" * 50)
    
    try:
        while True:
            # 1. Wait for the signal to go HIGH (RISING edge - Motion/Noise Start)
            pir_pin.wait_for_active()
            
            # Record the start time
            start_time = time.time()
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            
            # 2. Wait for the signal to go LOW (FALLING edge - NO TIMEOUT)
            # This will block until the pulse is genuinely over.
            pir_pin.wait_for_inactive()
            
            # Calculate duration
            end_time = time.time()
            duration = end_time - start_time
            
            # Determine status based on the defined noise threshold
            if duration < MIN_REAL_PULSE_DURATION:
                result_status = "NOISE SPIKE"
            else:
                result_status = "REAL MOTION"
            
            # Log and print the result
            log_to_csv(timestamp, duration, result_status)
            print(f"[{timestamp}] - Duration: {duration:.4f}s ({result_status}) -> Logged to CSV")
            
            # Add a small buffer before re-arming the wait
            time.sleep(0.1) 

    except KeyboardInterrupt:
        print("\nExiting pulse monitoring...")
    except Exception as e:
        print(f"An unexpected runtime error occurred: {e}")
    finally:
        pir_pin.close()
        print("Cleanup complete.")


# --- Main Execution ---
if __name__ == "__main__":
    monitor_pulse_width()