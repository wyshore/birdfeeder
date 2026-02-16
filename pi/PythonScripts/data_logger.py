# -*- coding: utf-8 -*-
"""
ENERGY DATA LOGGER

Reads voltage data from ADS1115 ADC and appends to local CSV file.
Avoids importing Firebase SDK to minimize memory usage.
Designed to run frequently via cron (e.g., every minute).

Data is uploaded later by data_uploader.py when app is open.
"""

import os
import sys
import csv
import time
import traceback
from datetime import datetime

# Import shared configuration
import shared_config as config

# ADS1115 library imports
try:
    import board
    import busio
    from adafruit_ads1x15.ads1115 import ADS1115
    from adafruit_ads1x15.analog_in import AnalogIn
except ImportError as e:
    print(f"FATAL: ADS1115 libraries not found: {e}")
    print("Install with: pip install adafruit-ads1x15")
    sys.exit(1)


def init_ads1115():
    """
    Initialize ADS1115 I2C connection.

    Returns:
        tuple: (solar_channel, battery_channel, i2c_bus) or (None, None, None) on failure
    """
    try:
        # Initialize I2C bus
        i2c = busio.I2C(board.SCL, board.SDA)

        # Create ADS1115 device
        ads = ADS1115(i2c, address=config.ADC_ADDRESS)
        ads.gain = config.ADC_GAIN

        # Create analog input channels
        solar_ch = AnalogIn(ads, config.SOLAR_VOLTAGE_CHANNEL)
        battery_ch = AnalogIn(ads, config.BATTERY_VOLTAGE_CHANNEL)

        # Warm-up: discard first conversions
        try:
            _ = solar_ch.value
            _ = battery_ch.value
            time.sleep(0.05)
            _ = solar_ch.voltage
            _ = battery_ch.voltage
            time.sleep(0.05)
        except Exception:
            pass

        return solar_ch, battery_ch, i2c

    except Exception as e:
        print(f"ERROR: ADS1115 initialization failed: {e}")
        traceback.print_exc()
        return None, None, None


def calculate_battery_percentage(voltage):
    """
    Calculate battery percentage from voltage.

    Args:
        voltage: Battery voltage (V)

    Returns:
        float: Battery percentage (0-100)
    """
    if voltage >= config.BATTERY_MAX_VOLTAGE:
        return 100
    if voltage <= config.BATTERY_MIN_VOLTAGE:
        return 0

    voltage_range = config.BATTERY_MAX_VOLTAGE - config.BATTERY_MIN_VOLTAGE
    percent = ((voltage - config.BATTERY_MIN_VOLTAGE) / voltage_range) * 100
    return round(max(0, min(100, percent)), 1)


if __name__ == "__main__":
    i2c_bus = None

    try:
        # Initialize hardware
        solar_ch, battery_ch, i2c_bus = init_ads1115()
        if solar_ch is None or battery_ch is None:
            print("ERROR: Failed to initialize ADS1115")
            sys.exit(1)

        # Read sensor data
        try:
            # Solar voltage (A0)
            solar_adc_voltage = solar_ch.voltage
            solar_voltage = solar_adc_voltage * config.SOLAR_VOLTAGE_DIVIDER

            # Battery voltage (A1)
            battery_adc_voltage = battery_ch.voltage
            battery_voltage = battery_adc_voltage * config.BATTERY_VOLTAGE_DIVIDER

            # Battery percentage
            battery_percent = calculate_battery_percentage(battery_voltage)

        except Exception as e:
            print(f"ERROR: Sensor read failed: {e}")
            traceback.print_exc()
            sys.exit(1)

        # Prepare data row
        timestamp = config.get_timestamp_string()
        data_row = [
            timestamp,
            round(solar_voltage, 3),
            round(battery_voltage, 3),
            battery_percent
        ]

        # Append to CSV file
        is_new_file = (
            not os.path.exists(config.ENERGY_LOG_FILE) or
            os.stat(config.ENERGY_LOG_FILE).st_size == 0
        )

        try:
            with open(config.ENERGY_LOG_FILE, 'a', newline='') as f:
                writer = csv.writer(f)

                # Write header if new file
                if is_new_file:
                    writer.writerow(['timestamp', 'solar_voltage', 'battery_voltage', 'battery_percent'])

                writer.writerow(data_row)

            print(f"Logged to {config.ENERGY_LOG_FILE}")
            print(f"Battery: {data_row[2]}V ({data_row[3]}%) | Solar: {data_row[1]}V")

        except Exception as e:
            print(f"ERROR: Failed to write CSV: {e}")
            traceback.print_exc()
            sys.exit(1)

    finally:
        # Cleanup I2C bus
        if i2c_bus is not None:
            try:
                i2c_bus.deinit()
            except AttributeError:
                pass
            del i2c_bus

        sys.exit(0)
