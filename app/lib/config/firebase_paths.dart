/// Centralized Firestore paths for the birdfeeder app.
///
/// This file contains all Firebase Firestore document and collection paths
/// used throughout the app. Centralizing these paths makes it easier to:
/// - Maintain consistency across the app
/// - Update paths in one place
/// - Avoid typos and path mismatches
library;

/// Status document paths (Pi state monitoring)
class StatusPaths {
  static const String heartbeat = 'status/heartbeat';
  static const String streamingEnabled = 'status/streaming_enabled';
  static const String appIsOpen = 'status/app_is_open';
  static const String testCapture = 'status/test_capture';
  static const String batchUploadRequest = 'status/batch_upload_request';
}

/// Config document paths (Settings)
class ConfigPaths {
  static const String settings = 'config/settings';
}

/// Log collection paths (Historical data)
class LogPaths {
  /// Energy data collection
  static const String energyData = 'logs/energy/data';

  /// Motion capture collection
  static const String motionCaptures = 'logs/motion_captures/data';

  /// Manual snapshot collection
  static const String snapshots = 'logs/snapshots/data';

  /// Bird sightings collection (identified captures)
  static const String sightings = 'logs/sightings/data';

  /// Test captures history
  static const String testCaptures = 'logs/test_captures/history';

  /// Helper method to get log collection path by ID
  /// Used by gallery_screen.dart for dynamic tab switching
  static String getLogPath(String collectionId) {
    return 'logs/$collectionId/data';
  }
}

/// Firebase Storage paths
class StoragePaths {
  static const String sightings = 'media/sightings';
  static const String snapshots = 'media/snapshots';
  static const String testCaptures = 'media/test_captures';
}
