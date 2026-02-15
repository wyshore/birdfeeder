# -*- coding: utf-8 -*-
"""
ENERGY DATA LOGGER (Step 2.2 - Low-Cost Local Logging)

This script reads voltage data and APPENDS it to a local CSV file.
It AVOIDS importing the heavy Firebase SDK to prevent memory spikes.
Data must be uploaded later by a separate 'dumper' script.
"""

import os
import sys
from datetime import datetime
import board
import busio
import time
import traceback
import csv

# ADS1115 Library Imports
try:
    # 1. Import the specific ADS1115 chip class directly
    from adafruit_ads1x15.ads1115 import ADS1115 
    # 2. Import the AnalogIn class
    from adafruit_ads1x15.analog_in import AnalogIn
    
    # Hardcoded pin indices
    P0_INDEX = 0
    P1_INDEX = 1

except ImportError:
    print("FATAL ERROR: ADS1115 libraries not found.")
    sys.exit(1)


# --- CONFIGURATION ---

# Local file path for storing collected data
LOCAL_LOG_FILE = "/home/wyattshore/Birdfeeder/Logs/energy_log.csv"

# ADS1115 Hardware Configuration
I2C_ADDRESS = 0x48 
ADS_GAIN_MULTIPLIER = 0.6666666666666666 

# Voltage Divider Ratios 
VOLTAGE_DIVIDER_RATIO_A0 = 2.419 # Solar Panel Voltage Multiplier
VOLTAGE_DIVIDER_RATIO_A1 = 1.435 # Battery Voltage Multiplier

# Battery Management Configuration 
BATTERY_MAX_VOLTAGE = 4.2 
BATTERY_MIN_VOLTAGE = 3.2 


# --- Helper Functions (Firebase related functions removed) ---

def init_ads1115():
    """Initializes the ADS1115 I2C connection and returns the channels."""
    try:
        # 1. Initialize the I2C bus
        i2c = busio.I2C(board.SCL, board.SDA)

        # 2. Create the ADS1115 object
        ads_device = ADS1115(i2c, address=I2C_ADDRESS)

        # 3. Configure the gain/FSR for the ADS
        ads_device.gain = ADS_GAIN_MULTIPLIER

        # 4. Create analog input channel objects
        channel_solar = AnalogIn(ads_device, P0_INDEX) 
        channel_battery = AnalogIn(ads_device, P1_INDEX) 

        # WARM-UP: discard the first conversion(s)
        try:
            _ = channel_solar.value
            _ = channel_battery.value
            time.sleep(0.05)
            _ = channel_solar.voltage
            _ = channel_battery.voltage
            time.sleep(0.05)
        except Exception:
            pass
        
        # print(">> ADS1115 I2C initialized.") # Keeping print statements minimal
        return channel_solar, channel_battery, i2c

    except Exception as e:
        print(f"ERROR: Failed to initialize ADS1115: {e}")
        return None, None, None

def calculate_battery_percentage(voltage):
    """Calculates battery percentage based on min/max voltage limits."""
    if voltage >= BATTERY_MAX_VOLTAGE:
        return 100
    if voltage <= BATTERY_MIN_VOLTAGE:
        return 0
    
    range_v = BATTERY_MAX_VOLTAGE - BATTERY_MIN_VOLTAGE
    percent = ((voltage - BATTERY_MIN_VOLTAGE) / range_v) * 100
    return round(max(0, min(100, percent)), 1) 
        
# --- Main Execution ---

if __name__ == "__main__":
    
    i2c_bus = None 

    try:
        # 1. Initialize Hardware
        channel_solar, channel_battery, i2c_bus = init_ads1115()
        if channel_solar is None or channel_battery is None:
            sys.exit(1)
            
        # 2. Read Sensor Data
        try:
            # Read Solar Data (A0)
            solar_adc_voltage = channel_solar.voltage 
            solar_voltage_actual = solar_adc_voltage * VOLTAGE_DIVIDER_RATIO_A0 
            
            # Read Battery Data (A1)
            battery_adc_voltage = channel_battery.voltage
            battery_voltage_actual = battery_adc_voltage * VOLTAGE_DIVIDER_RATIO_A1
            
            # Calculate Percentage
            battery_percent = calculate_battery_percentage(battery_voltage_actual)
            
        except Exception as e:
            print(f"FATAL ERROR during sensor read: {e}")
            traceback.print_exc(file=sys.stdout)
            sys.exit(1)
            
        # 3. Prepare Data Row
        # --- ADJUSTMENT HERE: Format timestamp to second precision ---
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        # We only log the three values you need: timestamp, solar V, battery V
        data_row = [
            timestamp,
            round(solar_voltage_actual, 3),
            round(battery_voltage_actual, 3),
            battery_percent
        ]

        # 4. Log Data to Local CSV File (APPEND mode)
        is_new_file = not os.path.exists(LOCAL_LOG_FILE) or os.stat(LOCAL_LOG_FILE).st_size == 0
        
        try:
            with open(LOCAL_LOG_FILE, 'a', newline='') as f:
                writer = csv.writer(f)
                
                # Write header only if the file is new or empty
                if is_new_file:
                    writer.writerow(['timestamp', 'solar_voltage', 'battery_voltage', 'battery_percent'])
                    
                writer.writerow(data_row)
            
            print(f"Logged {len(data_row)-1} values to local buffer: {LOCAL_LOG_FILE}")
            print(f"Battery V: {data_row[2]}V ({data_row[3]}%) | Solar V: {data_row[1]}V")

        except Exception as e:
            print(f"FATAL ERROR: Failed to write data to local CSV: {e}")
            traceback.print_exc(file=sys.stdout)
            sys.exit(1)
            
    finally:
        # Memory Cleanup
        if i2c_bus is not None:
            try:
                # The busio object might not have a deinit, but we try anyway
                i2c_bus.deinit() 
            except AttributeError:
                pass
            del i2c_bus 
            
        sys.exit(0)