# Phase 3: Motion Detection & CV Filtering

**Goal:** Reduce false positives through configurable thresholds and lightweight CV filtering.

## Part A: Configurable Motion Threshold
- Make 6.5s threshold adjustable via app settings
- Add field to `config/settings` Firestore doc
- Update `motion_capture.py` to read threshold from config
- Add slider in `settings_screen.dart`

## Part B: Local CV Filtering (Before Batch Upload)
Runs on Pi when batch upload triggers (app opens), NOT during individual captures.

### CV Filter Workflow
1. App opens → triggers batch upload process
2. **Before uploading**, iterate queue images
3. For each image:
   - Run lightweight CV (background subtraction vs. empty feeder reference)
   - Calculate difference score
   - If score < threshold → delete locally (false positive)
   - If score > threshold → upload (real motion)
4. Upload only validated images

### CV Techniques to Test (Ordered by Cost)
1. File size check (cheapest)
2. Background subtraction (OpenCV)
3. Edge detection + blob analysis
4. Brightness/contrast deltas

### Implementation
Create `raspberry_pi/utilities/cv_filter.py`:
- Function `filter_queue(queue_folder, reference_image_path, threshold)`
- Returns list of valid image paths
- Deletes invalid images

Call from `system_updater.py` before batch upload.

## Testing & Validation Phase (CRITICAL)

### 1. Data Collection
- Capture 100-200 test images (birds + false positives)
- Manually label each as "bird" or "false_positive"
- Store in `raspberry_pi/test_data/`

### 2. Algorithm Tuning
- Test different CV techniques and thresholds
- Measure precision and recall
- **GOAL: 0% false negatives** (never delete bird photo)
- Acceptable: <20% false positives slip through

### 3. Performance Validation
- Measure CPU usage during filtering
- Measure time to process 50 images
- Ensure <30s processing time
- Monitor CPU temperature

### 4. A/B Testing
- Run with CV filter for 1 week
- Compare: images captured vs. uploaded vs. real birds
- Validate no birds incorrectly filtered

## Success Criteria
✓ Zero false negatives
✓ 50%+ false positive reduction
✓ <10% CPU increase during batch processing
✓ No thermal throttling
