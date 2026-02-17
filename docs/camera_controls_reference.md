# Camera Controls Reference — IMX708 (RPi Camera Module 3 Wide)

Reference for all configurable Picamera2 controls available on the IMX708 sensor.
Settings are synced from the Flutter app via Firestore and applied by `motion_capture.py`.

---

## Quick Reference: Most Useful Controls for Bird Photos

| Priority | Control | Why |
|----------|---------|-----|
| **1** | ExposureTime | Short exposure (< 10ms) freezes bird motion |
| **2** | AnalogueGain | Compensates for light lost from short exposure |
| **3** | AfMode + LensPosition | Focus on feeder distance (~50-200mm) |
| **4** | Sharpness | Boost to recover detail lost from fast shutter |
| **5** | NoiseReductionMode | Balance between noise (from high gain) and detail |
| **6** | AeExposureMode | "short" mode biases auto-exposure toward faster shutter |

---

## Exposure Controls

### ExposureTime
- **Picamera2 key:** `ExposureTime`
- **Firestore key:** `exposure_time`
- **Type:** Integer (microseconds), 0 = auto
- **Range:** ~100 to ~112,000,000 (sensor max ~112ms at full res)
- **Effect:** Controls how long the sensor collects light per frame. Lower = less motion blur but darker image.
- **Bird photo tips:**
  - 1000-5000 us (1-5ms): Freezes fast wing motion, needs bright daylight or high gain
  - 5000-10000 us (5-10ms): Good balance for perched birds, slight blur on wings
  - 10000-20000 us (10-20ms): Fine for stationary subjects, visible blur on movement
  - 0 (auto): Camera chooses — often too slow for birds, causing motion blur
- **Trade-off:** Shorter exposure = less blur but darker image. Increase AnalogueGain to compensate.

### AnalogueGain
- **Picamera2 key:** `AnalogueGain`
- **Firestore key:** `analogue_gain`
- **Type:** Float, 0 = auto
- **Range:** 1.0 to 16.0 (hardware limit)
- **Effect:** Amplifies the sensor signal. Higher = brighter but more noise.
- **Bird photo tips:**
  - 1.0-2.0: Clean image, needs good light
  - 2.0-6.0: Moderate noise, usable for shorter exposures
  - 6.0-16.0: Noisy, use only if exposure time must be very short
- **Trade-off:** Higher gain = brighter image but more visible noise/grain. Pair with NoiseReductionMode.

### AeExposureMode
- **Picamera2 key:** `AeExposureMode`
- **Firestore key:** `ae_exposure_mode`
- **Type:** String/Integer
- **Values:** `normal` (0), `short` (1), `long` (2), `custom` (3)
- **Effect:** When auto-exposure is on, biases the algorithm's shutter speed preference.
- **Bird photo tips:**
  - `short` (1): Best for birds — tells AE to prefer faster shutter speeds, reducing motion blur while still auto-adjusting
  - `normal` (0): Default balanced mode
- **Note:** Only applies when AeEnable is True (auto exposure). Ignored if ExposureTime is set manually.

### ExposureValue (EV Compensation)
- **Picamera2 key:** `ExposureValue`
- **Firestore key:** `ev_compensation`
- **Type:** Float
- **Range:** -8.0 to +8.0 (practical range: -2.0 to +2.0)
- **Effect:** Shifts auto-exposure brightness target. Positive = brighter, negative = darker.
- **Bird photo tips:**
  - +0.5 to +1.0: Helps when birds are backlit or feeder is in shade
  - -0.5: Can help prevent blown-out highlights in direct sunlight
- **Note:** Only applies when AeEnable is True.

---

## Focus Controls

### AfMode
- **Picamera2 key:** `AfMode`
- **Firestore key:** `af_mode`
- **Type:** String/Integer
- **Values:** `manual` (0), `single` (1), `continuous` (2)
- **Effect:** Controls autofocus behavior.
- **Bird photo tips:**
  - `manual` (0) + LensPosition: **Best for birdfeeder.** Set focus to feeder distance and lock it. Eliminates AF hunting delay which can miss the bird.
  - `continuous` (2): AF continuously adjusts. May hunt/refocus between captures, adding delay and sometimes focusing on wrong area.
  - `single` (1): Focuses once when triggered (via AfTrigger). Not useful for motion-triggered capture.
- **Recommendation:** Use `manual` with a pre-measured LensPosition for the feeder.

### LensPosition
- **Picamera2 key:** `LensPosition`
- **Firestore key:** `lens_position`
- **Type:** Float (dioptres: 1/distance_in_metres)
- **Range:** 0.0 (infinity) to ~10.0 (very close, ~100mm)
- **Effect:** Sets manual focus distance. Only applies when AfMode = manual (0).
- **Key values for birdfeeder (0-200mm range):**
  - 0.0: Infinity focus
  - 1.0: ~1 metre
  - 2.0: ~500mm (50cm)
  - 3.0: ~333mm (33cm)
  - 5.0: ~200mm (20cm)
  - 7.0: ~143mm (14cm)
  - 10.0: ~100mm (10cm)
- **Bird photo tips:**
  - Measure distance from camera lens to feeder perch
  - Calculate: LensPosition = 1000 / distance_in_mm
  - Example: feeder 300mm away → LensPosition = 1000/300 = 3.33
  - Example: feeder 150mm away → LensPosition = 1000/150 = 6.67
  - Use `camera_test.py` to fine-tune — take test shots at different values near the calculated one
- **Recommendation:** This is the single most impactful setting for sharp bird photos at close range. Use `camera_test.py --af-mode manual --focus <value>` to dial it in.

---

## Image Processing Controls

### Sharpness
- **Picamera2 key:** `Sharpness`
- **Firestore key:** `sharpness`
- **Type:** Float
- **Range:** 0.0 to 16.0 (1.0 = default)
- **Effect:** Post-capture edge enhancement. Higher = sharper edges but can introduce artifacts.
- **Bird photo tips:**
  - 1.0-2.0: Slight boost, good for recovering softness from fast shutter
  - 2.0-4.0: Noticeable sharpening, good for feather detail
  - >4.0: Over-sharpened, creates halos around edges
- **Trade-off:** Over-sharpening amplifies noise. Keep lower if using high AnalogueGain.

### Contrast
- **Picamera2 key:** `Contrast`
- **Firestore key:** `contrast`
- **Type:** Float
- **Range:** 0.0 to 32.0 (1.0 = default)
- **Effect:** Adjusts difference between light and dark areas.
- **Bird photo tips:**
  - 1.0-1.5: Slight boost helps bird stand out from feeder/background
  - >2.0: Can lose detail in shadows and highlights
- **Usually fine at default (1.0).**

### Saturation
- **Picamera2 key:** `Saturation`
- **Firestore key:** `saturation`
- **Type:** Float
- **Range:** 0.0 to 32.0 (1.0 = default, 0.0 = greyscale)
- **Effect:** Controls colour intensity.
- **Bird photo tips:**
  - 1.0-1.3: Slight boost makes plumage colours more vivid
  - >2.0: Unnatural colour, loses detail
- **Usually fine at default (1.0).**

### Brightness
- **Picamera2 key:** `Brightness`
- **Firestore key:** `brightness`
- **Type:** Float
- **Range:** -1.0 to 1.0 (0.0 = default)
- **Effect:** Simple brightness offset applied after capture.
- **Bird photo tips:** Rarely needed — use EV compensation or exposure controls instead. This is a crude adjustment.
- **Usually leave at 0.0.**

---

## Noise & White Balance

### NoiseReductionMode
- **Picamera2 key:** `NoiseReductionMode`
- **Firestore key:** `noise_reduction`
- **Type:** String/Integer
- **Values:** `off` (0), `fast` (1), `high_quality` (2)
- **Effect:** Controls how aggressively the ISP removes sensor noise.
- **Bird photo tips:**
  - `high_quality` (2): Best for stills — more processing time but cleaner output. **Use this for motion captures.**
  - `fast` (1): Less aggressive, faster processing. Good for streaming.
  - `off` (0): No noise reduction. Only if you want to post-process later.
- **Trade-off:** Higher NR smooths noise but can also smooth fine detail (feather texture). If gain is low and light is good, `fast` may preserve more detail.

### AwbMode (Auto White Balance)
- **Picamera2 key:** `AwbMode`
- **Firestore key:** `awb_mode`
- **Type:** String/Integer
- **Values:** `auto` (0), `incandescent` (1), `tungsten` (2), `fluorescent` (3), `indoor` (4), `daylight` (5), `cloudy` (6)
- **Effect:** Sets the white balance preset for accurate colour reproduction.
- **Bird photo tips:**
  - `auto` (0): Usually fine for outdoor feeders
  - `daylight` (5): More consistent colours if feeder is in direct sun
  - `cloudy` (6): Warmer tones for overcast days
- **Usually fine at `auto` (0).**

---

## Recommended Starting Configurations

### Bright Daylight (Best Quality)
```
exposure_time: 3000        (3ms - freezes most motion)
analogue_gain: 0           (auto - low needed in bright light)
af_mode: manual
lens_position: <measured>  (calculate from feeder distance)
sharpness: 1.5
noise_reduction: high_quality
```

### Overcast / Shade
```
exposure_time: 8000        (8ms - balance of blur vs brightness)
analogue_gain: 4.0         (boost to compensate)
af_mode: manual
lens_position: <measured>
sharpness: 1.5
noise_reduction: high_quality
awb_mode: cloudy
```

### Auto Mode (Easiest, Less Optimal)
```
exposure_time: 0           (auto)
ae_exposure_mode: short    (bias toward faster shutter)
ev_compensation: 0.0
af_mode: continuous
sharpness: 1.5
noise_reduction: high_quality
```

---

## Notes

- **Stream resolution is fixed** at 640x360. Higher values crash the Pi Zero 2 W due to CPU load. Snapshot and motion capture resolutions can be configured independently.
- **Motion capture resolution** max is 4608x2592 (full IMX708 sensor). Higher resolution = more detail but larger files and slower upload.
- Camera controls are applied per-capture in `motion_capture.py` — changes take effect on the next motion trigger without restarting the service.
- Use `camera_test.py` on the Pi via SSH to experiment with settings before committing them to the app config.
