import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/bird.dart';
import 'bird_profile_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Catalog Screen — list of identified bird species
// ─────────────────────────────────────────────────────────────────────────────

enum _SortMode { sightingCount, lastSeen }

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  _SortMode _sortMode = _SortMode.sightingCount;

  Query<Map<String, dynamic>> get _query {
    final col = FirebaseFirestore.instance.collection(Bird.collectionPath);
    return _sortMode == _SortMode.sightingCount
        ? col.orderBy('sightingCount', descending: true).limit(100)
        : col.orderBy('lastSeen', descending: true).limit(100);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bird Catalog', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: theme.primaryColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: _sortMode == _SortMode.sightingCount ? 'Sort by last seen' : 'Sort by sighting count',
            icon: Icon(
              _sortMode == _SortMode.sightingCount ? Icons.access_time : Icons.format_list_numbered,
            ),
            onPressed: () => setState(() {
              _sortMode = _sortMode == _SortMode.sightingCount
                  ? _SortMode.lastSeen
                  : _SortMode.sightingCount;
            }),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _query.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error loading catalog: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final birds = snapshot.data!.docs.map((d) => Bird.fromFirestore(d)).toList();

          if (birds.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_stories, size: 72, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  const Text('Catalog is empty', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    'Identify a sighting in Activity to add species here.',
                    style: TextStyle(color: Colors.grey.shade600),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            itemCount: birds.length,
            itemBuilder: (context, index) {
              final bird = birds[index];
              return _BirdCard(
                bird: bird,
                rank: index + 1,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => BirdProfileScreen(bird: bird)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bird Card
// ─────────────────────────────────────────────────────────────────────────────

class _BirdCard extends StatelessWidget {
  final Bird bird;
  final int rank;
  final VoidCallback onTap;

  const _BirdCard({required this.bird, required this.rank, required this.onTap});

  String _formatDate(DateTime dt) {
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Rank badge
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: rank == 1
                      ? Colors.amber
                      : rank == 2
                          ? Colors.grey.shade400
                          : rank == 3
                              ? Colors.brown.shade300
                              : theme.primaryColor.withValues(alpha:0.12),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '#$rank',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      color: rank <= 3 ? Colors.white : theme.primaryColor,
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: bird.primaryImageUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: bird.primaryImageUrl,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) =>
                            const Icon(Icons.pets, size: 48, color: Colors.grey),
                      )
                    : Container(
                        width: 72,
                        height: 72,
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.pets, size: 36, color: Colors.grey),
                      ),
              ),

              const SizedBox(width: 14),

              // Name + stats
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bird.commonName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${bird.sightingCount} sighting${bird.sightingCount != 1 ? 's' : ''}',
                      style: TextStyle(color: theme.primaryColor, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'First: ${_formatDate(bird.firstSeen)}',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                    Text(
                      'Last: ${_formatDate(bird.lastSeen)}',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                  ],
                ),
              ),

              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
