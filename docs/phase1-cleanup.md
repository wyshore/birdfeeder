# Phase 1: Code Cleanup & Architecture Foundation

**Goal:** Clean, maintainable baseline with proper structure before adding features.

## Task Checklist

### 1. Create Shared Config Module (`raspberry_pi/core/config.py`)
Centralize all constants currently duplicated across scripts:
- Firebase service account path, project ID, bucket name
- Firestore collection paths (status, config, logs)
- Hardware config (GPIO pins, I2C address, voltage dividers)
- Single `init_firebase()` function that returns db client and storage bucket
- All scripts import from this module

**Files to update after creating config.py:**
- master_control.py
- camera_server.py
- system_updater.py
- motion_capture.py
- data_uploader.py
- data_logger.py
- storage_cleanup.py

### 2. Fix Known Bugs
- `camera_server.py` line 171: Change `tracebox.format_exc()` to `traceback.format_exc()`
- `master_control.py` line 396: Add f-prefix to string: `f"[HEARTBEAT] Pulse sent. Current IP: {current_ip}"`

### 3. Consolidate Duplicated Scripts
- Delete `config_updater.py` (superseded by `system_updater.py`)
- Extract shared normalization logic into `raspberry_pi/utils/config_normalizer.py`

### 4. Standardize Logging
Replace all `print()` statements with proper Python logging:
- Import logging at top of each script
- Configure logging with consistent format
- Use appropriate levels (INFO, WARNING, ERROR, CRITICAL)
- Remove all bare print() calls

### 5. Optimize Firebase Initialization
- Ensure all scripts use the shared `config.init_firebase()` function
- Remove duplicate Firebase app initialization
- Use named apps only where necessary (avoid conflicts)

### 6. Improve Process Management in master_control.py
- Add health check function that polls child process status
- Implement auto-restart on crash detection
- Better PID file validation (check if PID actually matches expected script)
- Add graceful shutdown handlers

### 7. Clean Up Flutter App
- Create `app/lib/config/firestore_paths.dart` with all path constants
- Replace `globals.dart` with provider-based state management (or riverpod)
- Extract TCP socket logic from `live_feed_screen.dart` into separate service class
- Update all screens to use centralized path constants

### 8. Optimize File Structure
**Reorganize Pi scripts into:**
```
raspberry_pi/
├── core/              # Essential system scripts
│   ├── master_control.py
│   ├── config.py      # NEW - shared config
│   └── __init__.py
├── services/          # Service scripts managed by master_control
│   ├── camera_server.py
│   ├── motion_capture.py
│   ├── system_updater.py
│   └── __init__.py
├── utilities/         # Helper scripts
│   ├── data_logger.py
│   ├── data_uploader.py
│   ├── storage_cleanup.py
│   ├── config_normalizer.py  # NEW - extracted logic
│   └── __init__.py
└── tests/             # Test/debug scripts (not in production)
    ├── cpu_logger.py
    ├── motion_test.py
    └── ADS1115_Quicktest.py
```

Move files, update imports, test on Pi after each move.

## Testing Strategy
**After each task:**
1. Test on Pi hardware (SSH, pull, run)
2. Verify all child processes still launch correctly
3. Check logs for errors
4. Confirm app can still connect and control system
5. Commit working state before moving to next task

**Final Phase 1 validation:**
- All scripts import from shared config
- No print() statements remain
- Dead code removed
- File structure is logical
- System runs without errors
- No functionality lost

## Success Criteria
✓ Single source of truth for all config values
✓ All bugs fixed
✓ Consistent logging throughout
✓ Clean, documented file structure
✓ System works exactly as before, but code is maintainable
✓ Ready for Phase 2 feature additions
