import 'package:cloud_firestore/cloud_firestore.dart';

/// Data model for a single bird sighting from the logs/sightings collection.
class Sighting {
  final String id;
  final DateTime timestamp;
  final String storagePath;
  final String imageUrl;
  final String resolution;

  // Catalog fields
  final bool isIdentified;
  final String catalogBirdId; // ID of the linked bird document (e.g., 'american-robin')
  final String speciesName;   // The human-readable name of the identified species

  // Source type: 'motion_capture' or 'snapshot'
  final String sourceType;

  Sighting({
    required this.id,
    required this.timestamp,
    required this.storagePath,
    required this.imageUrl,
    required this.resolution,
    required this.isIdentified,
    required this.catalogBirdId,
    required this.speciesName,
    this.sourceType = 'motion_capture',
  });

  /// Computed property to display "Unidentified" if tagging is pending.
  String get displaySpecies {
    return isIdentified && speciesName.isNotEmpty ? speciesName : 'Unidentified';
  }

  /// Factory constructor to create a Sighting object from a Firestore snapshot.
  factory Sighting.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    final Map<String, dynamic> fields = data ?? {};
    
    // Safety check for timestamp conversion
    final dynamic rawTimestamp = fields['timestamp']; 
    DateTime eventTimestamp;
    
    if (rawTimestamp is Timestamp) {
      eventTimestamp = rawTimestamp.toDate();
    } else if (rawTimestamp is String) {
      try {
        eventTimestamp = DateTime.parse(rawTimestamp);
      } catch (_) {
        eventTimestamp = DateTime.now();
      }
    } else {
      eventTimestamp = DateTime.now();
    }

    return Sighting(
      id: doc.id,
      timestamp: eventTimestamp,
      storagePath: fields['storagePath'] as String? ?? '', 
      imageUrl: fields['imageUrl'] as String? ?? '', 
      resolution: fields['resolution'] as String? ?? 'N/A', 
      
      isIdentified: fields['isIdentified'] as bool? ?? false,
      catalogBirdId: fields['catalogBirdId'] as String? ?? '',
      // Read 'speciesName' first, fall back to old 'species' field for existing docs
      speciesName: fields['speciesName'] as String? ?? fields['species'] as String? ?? '',
      sourceType: fields['sourceType'] as String? ?? 'motion_capture',
    );
  }
}