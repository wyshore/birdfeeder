import 'package:cloud_firestore/cloud_firestore.dart';

/// A motion capture instance — one motion event that may contain
/// multiple photos or a single video recording.
///
/// Corresponds to a document in logs/motion_captures/data/{instanceId}.
/// The document ID is the instance_id string (e.g. "inst_20240218_143022"),
/// written by the Pi's system_updater batch upload.
///
/// Note: fields use snake_case to match what the Pi writes.
class MotionInstance {
  final String id;                   // Firestore document ID (= instance_id)
  final DateTime timestamp;          // Start of motion event
  final double motionDuration;       // Seconds PIR was active
  final String captureMode;          // 'photo' | 'video'
  final int fileCount;               // Number of photos, or 1 for video
  final List<String> storagePaths;   // Firebase Storage paths for all files
  final List<String> imageUrls;      // Public download URLs for all files
  final String resolution;           // e.g. "4608x2592"
  final bool isIdentified;
  final String speciesName;
  final String catalogBirdId;
  final String sourceType;           // 'motion_capture'

  MotionInstance({
    required this.id,
    required this.timestamp,
    required this.motionDuration,
    required this.captureMode,
    required this.fileCount,
    required this.storagePaths,
    required this.imageUrls,
    required this.resolution,
    required this.isIdentified,
    required this.speciesName,
    required this.catalogBirdId,
    this.sourceType = 'motion_capture',
  });

  /// URL of the first image — used for thumbnail display.
  String get thumbnailUrl => imageUrls.isNotEmpty ? imageUrls.first : '';

  /// Whether this instance contains a video recording.
  bool get isVideo => captureMode == 'video';

  factory MotionInstance.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};

    DateTime parseTimestamp(dynamic raw) {
      if (raw is Timestamp) return raw.toDate();
      if (raw is String) {
        try {
          return DateTime.parse(raw);
        } catch (_) {}
      }
      return DateTime.now();
    }

    List<String> toStringList(dynamic v) {
      if (v is List) return v.map((e) => e.toString()).toList();
      return [];
    }

    return MotionInstance(
      id:             doc.id,
      timestamp:      parseTimestamp(data['timestamp']),
      motionDuration: (data['motion_duration'] as num?)?.toDouble() ?? 0.0,
      captureMode:    data['capture_mode'] as String? ?? 'photo',
      fileCount:      (data['file_count'] as num?)?.toInt() ?? 1,
      storagePaths:   toStringList(data['storage_paths']),
      imageUrls:      toStringList(data['image_urls']),
      resolution:     data['resolution'] as String? ?? '',
      isIdentified:   data['is_identified'] as bool? ?? false,
      speciesName:    data['species_name'] as String? ?? '',
      catalogBirdId:  data['catalog_bird_id'] as String? ?? '',
      sourceType:     data['source_type'] as String? ?? 'motion_capture',
    );
  }
}
