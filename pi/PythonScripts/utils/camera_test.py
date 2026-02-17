#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CAMERA TEST TOOL

Interactive tool for experimenting with Picamera2 camera settings
on the RPi Camera Module 3 Wide (IMX708 sensor).

Usage:
    # Capture with defaults (auto everything):
    python3 camera_test.py

    # Fast shutter for motion blur reduction:
    python3 camera_test.py --exposure 5000 --gain 4.0

    # Manual focus at specific distance + fast shutter:
    python3 camera_test.py --af-mode manual --focus 5.0 --exposure 3000

    # Continuous autofocus with enhanced sharpness:
    python3 camera_test.py --af-mode continuous --sharpness 1.5

    # Full manual control:
    python3 camera_test.py --exposure 8000 --gain 2.0 --af-mode manual --focus 4.0 --sharpness 1.2 --contrast 1.1

    # List all available controls and their ranges:
    python3 camera_test.py --list-controls

Photos are saved to: ~/Birdfeeder/pi/test_captures/
"""

import argparse
import os
import sys
import time
import json
from datetime import datetime

# Add parent directory to path so we can import shared_config
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import shared_config as config

try:
    from picamera2 import Picamera2
except ImportError:
    print("FATAL: Picamera2 not found. Install with: pip install picamera2")
    sys.exit(1)

# Output directory for test captures
TEST_CAPTURE_DIR = os.path.join(config.BASE_DIR, "test_captures")


def list_camera_controls():
    """List all available camera controls and their value ranges."""
    print("Querying camera for available controls...\n")

    picam2 = Picamera2()

    # Get camera properties
    props = picam2.camera_properties
    print("=== CAMERA PROPERTIES ===")
    print(f"  Model: {props.get('Model', 'Unknown')}")
    print(f"  Pixel Array: {props.get('PixelArraySize', 'Unknown')}")
    print(f"  Rotation: {props.get('Rotation', 'Unknown')}")
    print()

    # Get available controls
    controls = picam2.camera_controls
    print("=== AVAILABLE CONTROLS ===")
    print(f"{'Control':<25} {'Min':>12} {'Max':>12} {'Default':>12}")
    print("-" * 65)

    for name, (min_val, max_val, default) in sorted(controls.items()):
        # Format values nicely
        def fmt(v):
            if v is None:
                return "None"
            if isinstance(v, float):
                return f"{v:.4f}"
            return str(v)

        print(f"  {name:<23} {fmt(min_val):>12} {fmt(max_val):>12} {fmt(default):>12}")

    print()
    print("=== SENSOR MODES ===")
    for i, mode in enumerate(picam2.sensor_modes):
        size = mode.get('size', 'Unknown')
        fps = mode.get('fps', 'Unknown')
        fmt = mode.get('format', 'Unknown')
        print(f"  Mode {i}: {size} @ {fps}fps ({fmt})")

    picam2.close()
    print()
    print("Done. Camera closed.")


def capture_test_photo(args):
    """
    Capture a test photo with the specified camera settings.

    Args:
        args: Parsed command-line arguments
    """
    # Ensure output directory exists
    os.makedirs(TEST_CAPTURE_DIR, exist_ok=True)

    # Parse resolution
    resolution = tuple(args.resolution)

    print(f"=== CAMERA TEST CAPTURE ===")
    print(f"Resolution: {resolution[0]}x{resolution[1]}")
    print()

    # Initialize camera
    picam2 = Picamera2()
    camera_config = picam2.create_still_configuration(
        main={"size": resolution}
    )
    picam2.configure(camera_config)

    # Build controls dict from arguments
    controls = {}

    # --- Autofocus ---
    af_modes = {'manual': 0, 'single': 1, 'continuous': 2}
    af_mode_value = af_modes.get(args.af_mode, 2)
    controls['AfMode'] = af_mode_value

    if args.af_mode == 'manual' and args.focus is not None:
        controls['LensPosition'] = args.focus
        print(f"Focus: MANUAL (LensPosition={args.focus})")
    elif args.af_mode == 'single':
        controls['AfTrigger'] = 0
        print("Focus: SINGLE (will auto-focus once)")
    else:
        print(f"Focus: CONTINUOUS")

    # --- Exposure ---
    if args.exposure is not None:
        controls['ExposureTime'] = args.exposure
        controls['AeEnable'] = False
        print(f"Exposure: MANUAL ({args.exposure} us = {args.exposure/1000:.1f} ms)")

        # If exposure is manual, gain should also be set
        if args.gain is not None:
            controls['AnalogueGain'] = args.gain
            print(f"Gain: MANUAL ({args.gain}x)")
        else:
            print(f"Gain: AUTO (AeEnable will handle it)")
            # Actually if AeEnable is False and no gain set, it might be dark
            # Let's enable AeEnable if no gain specified
            controls['AeEnable'] = True
            print(f"  Note: Re-enabled AeEnable since no gain specified")
    else:
        controls['AeEnable'] = True
        if args.ev is not None:
            controls['ExposureValue'] = args.ev
            print(f"Exposure: AUTO (EV compensation: {args.ev})")
        else:
            print(f"Exposure: AUTO")

        if args.sport_mode:
            controls['AeExposureMode'] = 1  # Sport mode
            print(f"Exposure Mode: SPORT (faster shutter)")

        if args.gain is not None:
            controls['AnalogueGain'] = args.gain
            print(f"Gain: MANUAL ({args.gain}x)")
        else:
            print(f"Gain: AUTO")

    # --- White Balance ---
    if args.awb_mode is not None:
        awb_modes = {
            'auto': 0, 'incandescent': 1, 'tungsten': 2,
            'fluorescent': 3, 'indoor': 4, 'daylight': 5,
            'cloudy': 6
        }
        if args.awb_mode in awb_modes:
            controls['AwbEnable'] = True
            controls['AwbMode'] = awb_modes[args.awb_mode]
            print(f"White Balance: {args.awb_mode.upper()}")
    else:
        controls['AwbEnable'] = True
        print(f"White Balance: AUTO")

    # --- Image Quality Controls ---
    if args.sharpness is not None:
        controls['Sharpness'] = args.sharpness
        print(f"Sharpness: {args.sharpness}")

    if args.contrast is not None:
        controls['Contrast'] = args.contrast
        print(f"Contrast: {args.contrast}")

    if args.saturation is not None:
        controls['Saturation'] = args.saturation
        print(f"Saturation: {args.saturation}")

    if args.brightness is not None:
        controls['Brightness'] = args.brightness
        print(f"Brightness: {args.brightness}")

    if args.noise_reduction is not None:
        nr_modes = {'off': 0, 'fast': 1, 'high_quality': 2}
        if args.noise_reduction in nr_modes:
            controls['NoiseReductionMode'] = nr_modes[args.noise_reduction]
            print(f"Noise Reduction: {args.noise_reduction.upper()}")

    print()
    print(f"Controls to apply: {json.dumps({k: str(v) for k, v in controls.items()}, indent=2)}")
    print()

    # Start camera
    print("Starting camera...")
    picam2.start()

    # Apply controls
    picam2.set_controls(controls)

    # Wait for settings to take effect
    warmup = args.warmup
    print(f"Waiting {warmup}s for settings to stabilize...")
    time.sleep(warmup)

    # If single autofocus, trigger and wait
    if args.af_mode == 'single':
        print("Triggering autofocus...")
        picam2.set_controls({'AfTrigger': 0})
        time.sleep(2)  # Wait for AF to complete

    # Capture photo
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"test_{timestamp}.jpg"
    filepath = os.path.join(TEST_CAPTURE_DIR, filename)

    print(f"Capturing photo...")
    picam2.capture_file(filepath)

    # Get actual metadata from the captured frame
    metadata = picam2.capture_metadata()

    print(f"\nPhoto saved: {filepath}")
    file_size = os.path.getsize(filepath)
    print(f"File size: {file_size / 1024:.1f} KB ({file_size / 1024 / 1024:.2f} MB)")

    # Print actual capture metadata
    print(f"\n=== ACTUAL CAPTURE METADATA ===")
    interesting_keys = [
        'ExposureTime', 'AnalogueGain', 'DigitalGain',
        'Lux', 'ColourTemperature', 'FocusFoM',
        'LensPosition', 'AfState',
        'AeLocked', 'FrameDuration',
        'SensorTemperature',
    ]

    for key in interesting_keys:
        if key in metadata:
            val = metadata[key]
            if key == 'ExposureTime':
                print(f"  {key}: {val} us ({val/1000:.1f} ms)")
            elif key == 'FrameDuration':
                print(f"  {key}: {val} us ({1000000/val:.1f} fps)")
            else:
                print(f"  {key}: {val}")

    # Stop camera
    picam2.stop()
    picam2.close()

    print(f"\n=== DONE ===")
    print(f"Photo: {filepath}")

    # Save metadata alongside the photo
    metadata_path = filepath.replace('.jpg', '_metadata.json')
    # Convert metadata values to serializable types
    serializable_metadata = {}
    for k, v in metadata.items():
        try:
            json.dumps(v)
            serializable_metadata[k] = v
        except (TypeError, ValueError):
            serializable_metadata[k] = str(v)

    serializable_metadata['_test_settings'] = {k: str(v) for k, v in controls.items()}
    serializable_metadata['_resolution'] = list(resolution)

    with open(metadata_path, 'w') as f:
        json.dump(serializable_metadata, f, indent=2)

    print(f"Metadata: {metadata_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Camera test tool for RPi Camera Module 3 Wide (IMX708)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                                    # Auto everything (baseline)
  %(prog)s --exposure 5000 --gain 4.0         # Fast shutter for motion blur
  %(prog)s --af-mode manual --focus 5.0       # Fixed focus on feeder
  %(prog)s --af-mode continuous --sharpness 1.5  # Auto-focus + sharper
  %(prog)s --sport-mode                       # Auto exposure in sport mode
  %(prog)s --list-controls                    # Show all available controls
        """
    )

    # Info commands
    parser.add_argument('--list-controls', action='store_true',
                        help='List all available camera controls and exit')

    # Resolution
    parser.add_argument('--resolution', '-r', type=int, nargs=2,
                        default=[4608, 2592],
                        metavar=('W', 'H'),
                        help='Capture resolution (default: 4608 2592)')

    # Autofocus
    parser.add_argument('--af-mode', choices=['manual', 'single', 'continuous'],
                        default='continuous',
                        help='Autofocus mode (default: continuous)')
    parser.add_argument('--focus', type=float, default=None,
                        help='Manual focus position (used with --af-mode manual). '
                             'Higher values = closer focus. Try 2.0-10.0')

    # Exposure
    parser.add_argument('--exposure', '-e', type=int, default=None,
                        help='Manual exposure time in microseconds. '
                             'E.g., 5000 = 5ms (fast), 33000 = 33ms (normal)')
    parser.add_argument('--gain', '-g', type=float, default=None,
                        help='Analogue gain (ISO equivalent). '
                             'Higher = brighter but noisier. Try 1.0-8.0')
    parser.add_argument('--ev', type=float, default=None,
                        help='Exposure value compensation (-8.0 to 8.0). '
                             'Used with auto exposure only')
    parser.add_argument('--sport-mode', action='store_true',
                        help='Use sport exposure mode (shorter shutter times)')

    # White balance
    parser.add_argument('--awb-mode', choices=[
                            'auto', 'incandescent', 'tungsten',
                            'fluorescent', 'indoor', 'daylight', 'cloudy'],
                        default=None,
                        help='White balance mode (default: auto)')

    # Image quality
    parser.add_argument('--sharpness', type=float, default=None,
                        help='Sharpness (0.0-16.0, default ~1.0). Higher = sharper')
    parser.add_argument('--contrast', type=float, default=None,
                        help='Contrast (0.0-32.0, default ~1.0). Higher = more contrast')
    parser.add_argument('--saturation', type=float, default=None,
                        help='Saturation (0.0-32.0, default ~1.0). Higher = more vivid')
    parser.add_argument('--brightness', type=float, default=None,
                        help='Brightness (-1.0 to 1.0, default 0.0)')
    parser.add_argument('--noise-reduction', choices=['off', 'fast', 'high_quality'],
                        default=None,
                        help='Noise reduction mode')

    # Timing
    parser.add_argument('--warmup', type=float, default=2.0,
                        help='Seconds to wait for settings to stabilize (default: 2.0)')

    args = parser.parse_args()

    # Handle --list-controls
    if args.list_controls:
        list_camera_controls()
        return

    # Run capture
    capture_test_photo(args)


if __name__ == '__main__':
    main()
