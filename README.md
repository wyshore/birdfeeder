# Smart Birdfeeder

A solar-powered IoT birdfeeder built on Raspberry Pi Zero 2 W with real-time cloud integration and a Flutter desktop control app.

## Features

- **Motion-triggered capture** — PIR sensor detects birds, captures high-res photos
- **Live video streaming** — Hardware-encoded TCP JPEG stream viewable in desktop app
- **Solar power monitoring** — ADS1115 ADC tracks battery and solar panel voltage
- **Bird identification** — Catalog system for tracking species and sightings
- **Cloud sync** — Firebase Firestore + Storage for real-time config and data

## Project Structure

```
birdfeeder/
├── pi/           # Raspberry Pi Python code
│   ├── PythonScripts/
│   │   ├── master_control.py    # Main orchestrator
│   │   ├── motion_capture.py    # PIR-triggered photo capture
│   │   ├── camera_server.py     # TCP video streaming server
│   │   ├── system_updater.py    # Config sync + data upload
│   │   ├── data_logger.py       # Battery/solar logging
│   │   └── data_uploader.py     # Batch Firestore upload
│   └── birdfeeder-sa.json       # Firebase service account (NOT in git)
│
└── app/          # Flutter desktop application
    └── lib/
        ├── screens/             # UI screens
        ├── models/              # Data models
        └── main.dart            # App entry point
```

## Hardware

- Raspberry Pi Zero 2 W
- RPi Camera Module 3 Wide
- PIR motion sensor (GPIO pin 4)
- ADS1115 ADC (I2C 0x48)
- Solar panels + LiPo battery (3.2V-4.2V)

## Development Setup

**Pi-side:**
- Python 3.11+ with virtual environment
- Edit code locally, push to GitHub, pull on Pi to deploy
- SSH access for testing: `ssh pi@<ip-address>`

**Flutter app:**
- Flutter SDK installed locally
- Run/test: `flutter run -d windows` (or macos/linux)

**Firebase:**
- Project: `birdfeeder-b6224`
- Service account JSON required on Pi (see CLAUDE.md)

## Quick Start

1. Clone this repo
2. Set up Pi-side code (see `pi/README.md` when created)
3. Run Flutter app (see `app/README.md`)
4. Check `CLAUDE.md` for full architecture details

## Current Status

V1 is functional but undergoing incremental improvements for V2. See `CLAUDE.md` for known issues and roadmap.
