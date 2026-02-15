/// Data model for the /config/settings Firestore document.
class CameraSettings {
  // Resolution used for the live video stream (Read-only status)
  final List<int> streamResolution; 
  
  // A secondary snapshot resolution status, often a default or internal value (Read-only status)
  final List<int> snapshotResolution;

  // The high-resolution used for motion-triggered captures (Configurable)
  final List<int> motionCaptureResolution; 

  // Master switch to enable or disable the motion capture logic on the Pi (Configurable)
  final bool motionCaptureEnabled;
  
  // Read-only framerate of the stream (Read-only status)
  final int framerate;

  CameraSettings({
    required this.streamResolution,
    required this.snapshotResolution,
    required this.motionCaptureResolution,
    required this.motionCaptureEnabled,
    required this.framerate,
  }) : assert(streamResolution.length == 2 && snapshotResolution.length == 2 && motionCaptureResolution.length == 2);

  /// Default starting values if the document does not exist.
  static final defaultSettings = CameraSettings(
    streamResolution: [640, 360],
    snapshotResolution: [1280, 720],
    motionCaptureResolution: [4056, 3040], // The primary configurable capture resolution
    motionCaptureEnabled: false,
    framerate: 10,
  );

  /// Factory constructor to create a CameraSettings object from a Firestore Map.
  factory CameraSettings.fromFirestore(Map<String, dynamic> data) {
    // Helper function to safely cast List<dynamic> from Firestore to List<int>
    List<int> toIntList(dynamic list, List<int> defaultValue) {
      if (list is List) {
        try {
          return list.map((e) => e as int).toList();
        } catch (e) {
          return defaultValue;
        }
      }
      return defaultValue;
    }

    return CameraSettings(
      // Read-only keys (for status display)
      streamResolution: toIntList(data['stream_resolution'], defaultSettings.streamResolution),
      snapshotResolution: toIntList(data['snapshot_resolution'], defaultSettings.snapshotResolution),
      framerate: (data['framerate'] as int?) ?? defaultSettings.framerate,

      // Writable/Configurable keys
      motionCaptureResolution: toIntList(data['motion_capture_resolution'], defaultSettings.motionCaptureResolution),
      motionCaptureEnabled: (data['motion_capture_enabled'] as bool?) ?? defaultSettings.motionCaptureEnabled,
    );
  }

  /// Converts the CameraSettings object to a map for writing to Firestore.
  Map<String, dynamic> toFirestore() {
    // Only writable fields are included here.
    return {
      'motion_capture_resolution': motionCaptureResolution,
      'motion_capture_enabled': motionCaptureEnabled,
      // The other fields are set by the Pi, not the app.
    };
  }

  // Extension to help with creating new settings objects (immutability)
  CameraSettings copyWith({
    List<int>? streamResolution,
    List<int>? snapshotResolution,
    List<int>? motionCaptureResolution,
    bool? motionCaptureEnabled,
    int? framerate, 
  }) {
    return CameraSettings(
      streamResolution: streamResolution ?? this.streamResolution,
      snapshotResolution: snapshotResolution ?? this.snapshotResolution,
      motionCaptureResolution: motionCaptureResolution ?? this.motionCaptureResolution,
      motionCaptureEnabled: motionCaptureEnabled ?? this.motionCaptureEnabled,
      framerate: framerate ?? this.framerate,
    );
  }
}