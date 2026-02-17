import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a single identified bird species in the catalog.
class Bird {
  final String id;
  final String commonName;
  final String description;
  final String primaryImageUrl;
  final int sightingCount;
  final DateTime firstSeen;
  final DateTime lastSeen;

  Bird({
    required this.id,
    required this.commonName,
    required this.description,
    required this.primaryImageUrl,
    required this.sightingCount,
    required this.firstSeen,
    required this.lastSeen,
  });

  factory Bird.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final lastSeen = (data['lastSeen'] as Timestamp?)?.toDate() ?? DateTime.now();
    return Bird(
      id: doc.id,
      commonName: data['commonName'] ?? 'Unknown Species',
      description: data['description'] ?? '',
      primaryImageUrl: data['primaryImageUrl'] ?? '',
      sightingCount: (data['sightingCount'] as num?)?.toInt() ?? 0,
      firstSeen: (data['firstSeen'] as Timestamp?)?.toDate() ?? lastSeen,
      lastSeen: lastSeen,
    );
  }

  /// Generates the initial data map when creating a new catalog entry.
  static Map<String, dynamic> createNewCatalogEntry({
    required String speciesName,
    required String imageStoragePath,
    String description = '',
  }) {
    return {
      'commonName': speciesName,
      'description': description,
      'primaryImageUrl': imageStoragePath,
      'sightingCount': 1,
      'firstSeen': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'lastSeen': FieldValue.serverTimestamp(),
    };
  }

  /// Firestore collection path for the catalog.
  static const String collectionPath = 'catalog/birds/data';
}
