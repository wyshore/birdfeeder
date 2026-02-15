import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a single identified bird in the public catalog.
class Bird {
  final String id;
  final String commonName;
  // Removed: final String scientificName;
  final String description;
  final String primaryImageUrl;
  final int sightingCount;
  final DateTime lastSeen;

  Bird({
    required this.id,
    required this.commonName,
    // Removed: required this.scientificName,
    required this.description,
    required this.primaryImageUrl,
    required this.sightingCount,
    required this.lastSeen,
  });

  /// Factory constructor to create a Bird instance from a Firestore document.
  factory Bird.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Bird(
      id: doc.id,
      commonName: data['commonName'] ?? 'Unknown Species',
      // Removed: scientificName: data['scientificName'] ?? '',
      description: data['description'] ?? '',
      primaryImageUrl: data['primaryImageUrl'] ?? '',
      sightingCount: (data['sightingCount'] as num?)?.toInt() ?? 0,
      lastSeen: (data['lastSeen'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  /// Static helper to generate the initial data map for a new catalog entry.
  static Map<String, dynamic> createNewCatalogEntry({
    required String speciesName,
    required String imageStoragePath,
    String description = 'A newly recorded species.',
  }) {
    // We removed the 'scientificName' field from the document map.
    return {
      'commonName': speciesName,
      'description': description,
      'primaryImageUrl': imageStoragePath,
      'sightingCount': 1, // Start at 1 because this is the first sighting
      'createdAt': FieldValue.serverTimestamp(),
      'lastSeen': FieldValue.serverTimestamp(),
    };
  }
}

/// --- Main Catalog Screen ---
class CatalogScreen extends StatelessWidget {
  const CatalogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // This collection reference is the same one used for writing in gallery_screen.dart
    final catalogCollection = FirebaseFirestore.instance
        .collection('catalog')
        .doc('birds')
        .collection('data')
        .orderBy('sightingCount', descending: true)
        .limit(100);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bird Catalog (Top Sightings)', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).primaryColor,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: catalogCollection.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error loading catalog: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final birds = snapshot.data!.docs
              .map((doc) => Bird.fromFirestore(doc))
              .toList();

          if (birds.isEmpty) {
            return const Center(
                child: Text('The catalog is empty! Identify a bird to add one.', style: TextStyle(fontSize: 18))
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12.0),
            itemCount: birds.length,
            itemBuilder: (context, index) {
              final bird = birds[index];
              return Card(
                elevation: 2,
                margin: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(8),
                  leading: bird.primaryImageUrl.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(
                            bird.primaryImageUrl,
                            width: 60,
                            height: 60,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(Icons.image_not_supported, size: 40, color: Colors.grey),
                          ),
                        )
                      : const Icon(Icons.pets, size: 40, color: Colors.blueGrey),
                  
                  title: Text(
                    bird.commonName, 
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)
                  ),
                  subtitle: Text(
                    'Sighted ${bird.sightingCount} times (Last: ${bird.lastSeen.day}/${bird.lastSeen.month})',
                    style: TextStyle(color: Colors.grey.shade600)
                  ),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '#${index + 1}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold, 
                        color: Theme.of(context).primaryColor
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}