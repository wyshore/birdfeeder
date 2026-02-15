# ads1115_quick_test.py
# A script to quickly verify the ADS1115 I2C connection and functionality,
# reading data from both Analog Inputs A0 (P0) and A1 (P1).

import time
import board
import busio

# === FINAL SOLUTION: HARDCODING PIN CONSTANTS TO BYPASS BROKEN LIBRARY IMPORTS ===
# Since all standard import paths for P0/P1 are failing due to a non-standard
# library installation, we will use the literal integer values for the pins (0 and 1)
# to finally bypass the ImportError and test the device.

# 1. Import the specific ADS1115 class
from adafruit_ads1x15.ads1115 import ADS1115 
# 2. Import the AnalogIn class
from adafruit_ads1x15.analog_in import AnalogIn

# P0 and P1 imports have been removed to fix the ModuleNotFoundError.

# --- Configuration ---
I2C_ADDRESS = 0x48 # Default I2C address
ADS_GAIN_MULTIPLIER = 0.6666666666666666
# Corresponds to +/- 6.144V FSR.

# --- Setup I2C and ADS1115 ---
try:
    # 1. Initialize the I2C bus
    i2c = busio.I2C(board.SCL, board.SDA)

    # 2. Create the ADS1115 object
    ads_device = ADS1115(i2c, address=I2C_ADDRESS)

    # 3. Configure the gain/FSR for the ADS
    ads_device.gain = ADS_GAIN_MULTIPLIER

    # 4. Create analog input channel objects for A0 (P0=0) and A1 (P1=1)
    # The AnalogIn constructor accepts the integer value of the pin index.
    # This bypasses the need to import the problematic P0 and P1 constants.
    P0_INDEX = 0
    P1_INDEX = 1
    channel_a0 = AnalogIn(ads_device, P0_INDEX) 
    channel_a1 = AnalogIn(ads_device, P1_INDEX)

except Exception as e:
    # We now see the real traceback if initialization fails for a hardware reason.
    print("--------------------------------------------------------------------")
    print("ERROR: Failed to initialize ADS1115.")
    print("The initialization failed. Please check wiring and I2C settings.")
    print(f"Details: {e}")
    print("--------------------------------------------------------------------")
    exit()

# --- Main Loop ---
print("--- ADS1115 Dual Channel Test (A0 & A1) ---")
print(f"FSR set to: +/- 6.144V (using gain multiplier {ADS_GAIN_MULTIPLIER})")
print("-" * 55)
print(f"| {'Channel':<7} | {'Raw Counts':<12} | {'Voltage (V)':<12} |")
print("-" * 55)

while True:
    try:
        # Read data from A0 (P0)
        raw_a0 = channel_a0.value
        # Apply the calibration/scaling factor for A0
        voltage_a0 = channel_a0.voltage * 2.419
        
        # Read data from A1 (P1)
        raw_a1 = channel_a1.value
        # Apply the calibration/scaling factor for A1
        voltage_a1 = channel_a1.voltage * 1.435
        
        # Print the results in a formatted table row
        print(f"| {'A0 (P0)':<7} | {raw_a0:<12} | {voltage_a0:12.3f} |")
        print(f"| {'A1 (P1)':<7} | {raw_a1:<12} | {voltage_a1:12.3f} |")
        print("-" * 55)
        
        time.sleep(0.5)

    except KeyboardInterrupt:
        print("\nTest stopped by user.")
        break
    except Exception as e:
        print(f"\nAn error occurred during reading: {e}")
        break
