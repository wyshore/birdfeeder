/// Data model for the /config/settings Firestore document.
class CameraSettings {
  // --- Read-only status fields (set by Pi) ---
  final List<int> streamResolution;
  final List<int> snapshotResolution;
  final int framerate;

  // --- Configurable fields (set by app) ---
  final List<int> motionCaptureResolution;
  final bool motionCaptureEnabled;
  final double motionThresholdSeconds; // Seconds of sustained motion (post-capture discard filter)

  // Capture mode
  final String captureMode;           // 'photo' | 'video'
  final double photoCaptureInterval;  // Seconds between photos (1.0 - 60.0)
  final String videoDurationMode;     // 'fixed' | 'motion'
  final double videoFixedDuration;    // Seconds for fixed-length video (1.0 - 120.0)

  // Focus
  final String afMode; // "manual", "continuous"
  final double lensPosition; // 0.0 (infinity) - 10.0 (close), only used when afMode = "manual"

  // Exposure
  final int exposureTime; // 0 = auto, >0 = manual (microseconds), max 66666
  final double analogueGain; // 0 = auto, 1.0-16.0 = manual
  final String aeExposureMode; // "normal", "short"
  final double evCompensation; // -8.0 to 8.0

  // Image processing
  final double sharpness; // 0.0 - 16.0
  final double contrast; // 0.0 - 32.0
  final double saturation; // 0.0 - 32.0
  final double brightness; // -1.0 - 1.0

  // Other
  final String noiseReduction; // "off", "fast", "high_quality"
  final String awbMode; // "auto", "daylight", "cloudy", "tungsten", "fluorescent", "indoor", "incandescent"

  CameraSettings({
    required this.streamResolution,
    required this.snapshotResolution,
    required this.framerate,
    required this.motionCaptureResolution,
    required this.motionCaptureEnabled,
    required this.motionThresholdSeconds,
    required this.captureMode,
    required this.photoCaptureInterval,
    required this.videoDurationMode,
    required this.videoFixedDuration,
    required this.afMode,
    required this.lensPosition,
    required this.exposureTime,
    required this.analogueGain,
    required this.aeExposureMode,
    required this.evCompensation,
    required this.sharpness,
    required this.contrast,
    required this.saturation,
    required this.brightness,
    required this.noiseReduction,
    required this.awbMode,
  });

  static final defaultSettings = CameraSettings(
    streamResolution: [640, 360],
    snapshotResolution: [1280, 720],
    framerate: 10,
    motionCaptureResolution: [4608, 2592],
    motionCaptureEnabled: false,
    motionThresholdSeconds: 6.5,
    captureMode: 'photo',
    photoCaptureInterval: 5.0,
    videoDurationMode: 'motion',
    videoFixedDuration: 10.0,
    afMode: 'continuous',
    lensPosition: 1.0,
    exposureTime: 0,
    analogueGain: 0,
    aeExposureMode: 'normal',
    evCompensation: 0.0,
    sharpness: 1.0,
    contrast: 1.0,
    saturation: 1.0,
    brightness: 0.0,
    noiseReduction: 'high_quality',
    awbMode: 'auto',
  );

  factory CameraSettings.fromFirestore(Map<String, dynamic> data) {
    List<int> toIntList(dynamic list, List<int> defaultValue) {
      if (list is List) {
        try {
          return list.map((e) => (e as num).toInt()).toList();
        } catch (e) {
          return defaultValue;
        }
      }
      return defaultValue;
    }

    final d = defaultSettings;
    return CameraSettings(
      // Read-only
      streamResolution: toIntList(data['stream_resolution'], d.streamResolution),
      snapshotResolution: toIntList(data['snapshot_resolution'], d.snapshotResolution),
      framerate: (data['framerate'] as num?)?.toInt() ?? d.framerate,
      // Configurable
      motionCaptureResolution: toIntList(data['motion_capture_resolution'], d.motionCaptureResolution),
      motionCaptureEnabled: (data['motion_capture_enabled'] as bool?) ?? d.motionCaptureEnabled,
      motionThresholdSeconds: (data['motion_threshold_seconds'] as num?)?.toDouble() ?? d.motionThresholdSeconds,
      captureMode: (data['capture_mode'] as String?) ?? d.captureMode,
      photoCaptureInterval: (data['photo_capture_interval'] as num?)?.toDouble() ?? d.photoCaptureInterval,
      videoDurationMode: (data['video_duration_mode'] as String?) ?? d.videoDurationMode,
      videoFixedDuration: (data['video_fixed_duration'] as num?)?.toDouble() ?? d.videoFixedDuration,
      afMode: (data['af_mode'] as String?) ?? d.afMode,
      lensPosition: (data['lens_position'] as num?)?.toDouble() ?? d.lensPosition,
      exposureTime: (data['exposure_time'] as num?)?.toInt() ?? d.exposureTime,
      analogueGain: (data['analogue_gain'] as num?)?.toDouble() ?? d.analogueGain,
      aeExposureMode: (data['ae_exposure_mode'] as String?) ?? d.aeExposureMode,
      evCompensation: (data['ev_compensation'] as num?)?.toDouble() ?? d.evCompensation,
      sharpness: (data['sharpness'] as num?)?.toDouble() ?? d.sharpness,
      contrast: (data['contrast'] as num?)?.toDouble() ?? d.contrast,
      saturation: (data['saturation'] as num?)?.toDouble() ?? d.saturation,
      brightness: (data['brightness'] as num?)?.toDouble() ?? d.brightness,
      noiseReduction: (data['noise_reduction'] as String?) ?? d.noiseReduction,
      awbMode: (data['awb_mode'] as String?) ?? d.awbMode,
    );
  }

  /// Only writable fields sent to Firestore.
  Map<String, dynamic> toFirestore() {
    return {
      'motion_capture_resolution': motionCaptureResolution,
      'motion_capture_enabled': motionCaptureEnabled,
      'motion_threshold_seconds': motionThresholdSeconds,
      'capture_mode': captureMode,
      'photo_capture_interval': photoCaptureInterval,
      'video_duration_mode': videoDurationMode,
      'video_fixed_duration': videoFixedDuration,
      'af_mode': afMode,
      'lens_position': lensPosition,
      'exposure_time': exposureTime,
      'analogue_gain': analogueGain,
      'ae_exposure_mode': aeExposureMode,
      'ev_compensation': evCompensation,
      'sharpness': sharpness,
      'contrast': contrast,
      'saturation': saturation,
      'brightness': brightness,
      'noise_reduction': noiseReduction,
      'awb_mode': awbMode,
    };
  }

  CameraSettings copyWith({
    List<int>? streamResolution,
    List<int>? snapshotResolution,
    int? framerate,
    List<int>? motionCaptureResolution,
    bool? motionCaptureEnabled,
    double? motionThresholdSeconds,
    String? captureMode,
    double? photoCaptureInterval,
    String? videoDurationMode,
    double? videoFixedDuration,
    String? afMode,
    double? lensPosition,
    int? exposureTime,
    double? analogueGain,
    String? aeExposureMode,
    double? evCompensation,
    double? sharpness,
    double? contrast,
    double? saturation,
    double? brightness,
    String? noiseReduction,
    String? awbMode,
  }) {
    return CameraSettings(
      streamResolution: streamResolution ?? this.streamResolution,
      snapshotResolution: snapshotResolution ?? this.snapshotResolution,
      framerate: framerate ?? this.framerate,
      motionCaptureResolution: motionCaptureResolution ?? this.motionCaptureResolution,
      motionCaptureEnabled: motionCaptureEnabled ?? this.motionCaptureEnabled,
      motionThresholdSeconds: motionThresholdSeconds ?? this.motionThresholdSeconds,
      captureMode: captureMode ?? this.captureMode,
      photoCaptureInterval: photoCaptureInterval ?? this.photoCaptureInterval,
      videoDurationMode: videoDurationMode ?? this.videoDurationMode,
      videoFixedDuration: videoFixedDuration ?? this.videoFixedDuration,
      afMode: afMode ?? this.afMode,
      lensPosition: lensPosition ?? this.lensPosition,
      exposureTime: exposureTime ?? this.exposureTime,
      analogueGain: analogueGain ?? this.analogueGain,
      aeExposureMode: aeExposureMode ?? this.aeExposureMode,
      evCompensation: evCompensation ?? this.evCompensation,
      sharpness: sharpness ?? this.sharpness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      brightness: brightness ?? this.brightness,
      noiseReduction: noiseReduction ?? this.noiseReduction,
      awbMode: awbMode ?? this.awbMode,
    );
  }
}
