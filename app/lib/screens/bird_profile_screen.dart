import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/bird.dart';
import '../models/sighting.dart';
import '../config/firebase_paths.dart';
import '../utils/string_extensions.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data helper — wraps a Sighting with the Firestore collection it came from
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileSighting {
  final Sighting sighting;
  final String collectionPath;
  _ProfileSighting(this.sighting, this.collectionPath);
}

// ─────────────────────────────────────────────────────────────────────────────
// Bird Profile Screen
// ─────────────────────────────────────────────────────────────────────────────

class BirdProfileScreen extends StatefulWidget {
  final Bird bird;
  const BirdProfileScreen({super.key, required this.bird});

  @override
  State<BirdProfileScreen> createState() => _BirdProfileScreenState();
}

class _BirdProfileScreenState extends State<BirdProfileScreen> {
  late Bird _bird;
  late Stream<List<_ProfileSighting>> _sightingsStream;

  @override
  void initState() {
    super.initState();
    _bird = widget.bird;
    _sightingsStream = _buildSightingsStream();
  }

  // ── Stream: merge both collections, no orderBy = no composite index needed ──

  Stream<List<_ProfileSighting>> _buildSightingsStream() {
    final firestore = FirebaseFirestore.instance;

    // Equality-only filter uses Firestore's auto single-field index — no composite index needed
    final motionStream = firestore
        .collection(LogPaths.motionCaptures)
        .where('catalogBirdId', isEqualTo: _bird.id)
        .snapshots()
        .map((s) => s.docs
            .map((d) => _ProfileSighting(Sighting.fromFirestore(d), LogPaths.motionCaptures))
            .toList());

    final snapshotStream = firestore
        .collection(LogPaths.snapshots)
        .where('catalogBirdId', isEqualTo: _bird.id)
        .snapshots()
        .map((s) => s.docs
            .map((d) => _ProfileSighting(Sighting.fromFirestore(d), LogPaths.snapshots))
            .toList());

    return _combineLatest(motionStream, snapshotStream);
  }

  Stream<List<_ProfileSighting>> _combineLatest(
    Stream<List<_ProfileSighting>> a,
    Stream<List<_ProfileSighting>> b,
  ) {
    final controller = StreamController<List<_ProfileSighting>>();
    List<_ProfileSighting>? latestA;
    List<_ProfileSighting>? latestB;

    void emit() {
      if (latestA != null && latestB != null) {
        final combined = [...latestA!, ...latestB!];
        combined.sort((x, y) => y.sighting.timestamp.compareTo(x.sighting.timestamp));
        controller.add(combined);
      }
    }

    final subA = a.listen((data) { latestA = data; emit(); }, onError: controller.addError);
    final subB = b.listen((data) { latestB = data; emit(); }, onError: controller.addError);

    controller.onCancel = () {
      subA.cancel();
      subB.cancel();
    };

    return controller.stream;
  }

  // ── Edit species name ──────────────────────────────────────────────────────

  Future<void> _editName() async {
    final controller = TextEditingController(text: _bird.commonName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Species Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g., American Robin'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty || result == _bird.commonName) return;

    final newName = result.toTitleCase();
    try {
      await FirebaseFirestore.instance
          .collection(Bird.collectionPath)
          .doc(_bird.id)
          .update({'commonName': newName});
      setState(() => _bird = Bird(
            id: _bird.id,
            commonName: newName,
            description: _bird.description,
            primaryImageUrl: _bird.primaryImageUrl,
            sightingCount: _bird.sightingCount,
            firstSeen: _bird.firstSeen,
            lastSeen: _bird.lastSeen,
          ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
      }
    }
  }

  // ── Set cover photo ────────────────────────────────────────────────────────

  Future<void> _setCoverPhoto(String imageUrl) async {
    try {
      await FirebaseFirestore.instance
          .collection(Bird.collectionPath)
          .doc(_bird.id)
          .update({'primaryImageUrl': imageUrl});
      setState(() => _bird = Bird(
            id: _bird.id,
            commonName: _bird.commonName,
            description: _bird.description,
            primaryImageUrl: imageUrl,
            sightingCount: _bird.sightingCount,
            firstSeen: _bird.firstSeen,
            lastSeen: _bird.lastSeen,
          ));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Cover photo updated.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  // ── Delete species ─────────────────────────────────────────────────────────

  Future<void> _deleteSpecies(List<_ProfileSighting> profileSightings) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Species?'),
        content: Text(
          'This will remove "${_bird.commonName}" from the catalog and unlink '
          '${profileSightings.length} sighting${profileSightings.length != 1 ? 's' : ''}. '
          'Photos will be moved back to Activity.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final firestore = FirebaseFirestore.instance;
      final batch = firestore.batch();
      for (final ps in profileSightings) {
        batch.update(
          firestore.collection(ps.collectionPath).doc(ps.sighting.id),
          {'isIdentified': false, 'catalogBirdId': '', 'speciesName': ''},
        );
      }
      batch.delete(firestore.collection(Bird.collectionPath).doc(_bird.id));
      await batch.commit();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  // ── Unidentify: move sighting back to Activity ─────────────────────────────

  Future<void> _unidentify(_ProfileSighting ps) async {
    final firestore = FirebaseFirestore.instance;
    final catalogRef = firestore.collection(Bird.collectionPath).doc(_bird.id);
    final sightingRef = firestore.collection(ps.collectionPath).doc(ps.sighting.id);

    try {
      await firestore.runTransaction((txn) async {
        txn.update(catalogRef, {'sightingCount': FieldValue.increment(-1)});
        txn.update(sightingRef, {
          'isIdentified': false,
          'catalogBirdId': '',
          'speciesName': '',
        });
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Moved back to Activity.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  // ── Reassign: move sighting to a different species ─────────────────────────

  void _openReassignSheet(_ProfileSighting ps) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ReassignSheet(
        ps: ps,
        currentBirdId: _bird.id,
      ),
    );
  }

  // ── Photo tap: open detail viewer with side actions ───────────────────────

  void _onPhotoTap(_ProfileSighting ps) {
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      barrierDismissible: true,
      barrierLabel: 'Close',
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (ctx, a1, a2) => _PhotoDetailScreen(
        ps: ps,
        bird: _bird,
        onSetCover: () => _setCoverPhoto(ps.sighting.imageUrl),
        onReassign: () => _openReassignSheet(ps),
        onUnidentify: () => _unidentify(ps),
      ),
      transitionBuilder: (ctx, a1, a2, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(a1),
        child: child,
      ),
    );
  }

  void _showCoverPicker(List<_ProfileSighting> profileSightings) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        maxChildSize: 0.85,
        expand: false,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Select Cover Photo',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Expanded(
              child: GridView.builder(
                controller: scrollCtrl,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4,
                ),
                itemCount: profileSightings.length,
                itemBuilder: (_, i) {
                  final ps = profileSightings[i];
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _setCoverPhoto(ps.sighting.imageUrl);
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(
                          imageUrl: ps.sighting.imageUrl, fit: BoxFit.cover),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<List<_ProfileSighting>>(
      stream: _sightingsStream,
      builder: (context, snapshot) {
        // Show errors explicitly instead of silently returning empty
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(
              backgroundColor: theme.primaryColor,
              foregroundColor: Colors.white,
              title: Text(_bird.commonName),
            ),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Error loading sightings:\n${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ),
          );
        }

        final profileSightings = snapshot.data ?? [];
        final sightings = profileSightings.map((ps) => ps.sighting).toList();

        return Scaffold(
          appBar: AppBar(
            backgroundColor: theme.primaryColor,
            foregroundColor: Colors.white,
            title: Text(
              _bird.commonName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
            ),
            actions: [
              IconButton(icon: const Icon(Icons.edit), tooltip: 'Edit name', onPressed: _editName),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete species',
                onPressed: () => _deleteSpecies(profileSightings),
              ),
            ],
          ),
          body: CustomScrollView(
            slivers: [
              // ── Cover photo card ──────────────────────────────────────────
              SliverToBoxAdapter(
                child: _CoverPhotoCard(
                  bird: _bird,
                  onChangeCover: profileSightings.isEmpty
                      ? null
                      : () => _showCoverPicker(profileSightings),
                ),
              ),

              // ── Stats row ─────────────────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      _StatCard(
                        label: 'Sightings',
                        value: '${_bird.sightingCount}',
                        icon: Icons.photo_camera,
                        color: theme.primaryColor,
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        label: 'First seen',
                        value: _formatShortDate(_bird.firstSeen),
                        icon: Icons.star_outline,
                        color: Colors.green.shade600,
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        label: 'Last seen',
                        value: _formatShortDate(_bird.lastSeen),
                        icon: Icons.access_time,
                        color: Colors.orange.shade700,
                      ),
                    ],
                  ),
                ),
              ),

              // ── Time of day histogram ─────────────────────────────────────
              if (sightings.isNotEmpty) ...[
                _SectionHeader(title: 'Time of Day'),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: _TimeOfDayChart(sightings: sightings),
                  ),
                ),
              ],

              // ── Time of year histogram ────────────────────────────────────
              if (sightings.isNotEmpty) ...[
                _SectionHeader(title: 'Time of Year'),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: _TimeOfYearChart(sightings: sightings),
                  ),
                ),
              ],

              // ── Photo grid ────────────────────────────────────────────────
              if (profileSightings.isNotEmpty) ...[
                _SectionHeader(title: 'All Sightings (${profileSightings.length})'),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final ps = profileSightings[i];
                        final isCover = ps.sighting.imageUrl == _bird.primaryImageUrl;
                        return GestureDetector(
                          onTap: () => _onPhotoTap(ps),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(
                                  imageUrl: ps.sighting.imageUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) =>
                                      Container(color: Colors.grey.shade200),
                                  errorWidget: (_, __, ___) => const Icon(
                                      Icons.image_not_supported,
                                      color: Colors.grey),
                                ),
                              ),
                              if (isCover)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: const BoxDecoration(
                                        color: Colors.amber, shape: BoxShape.circle),
                                    child: const Icon(Icons.star,
                                        size: 12, color: Colors.white),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                      childCount: profileSightings.length,
                    ),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 6,
                      mainAxisSpacing: 6,
                      childAspectRatio: 1,
                    ),
                  ),
                ),
              ] else ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        snapshot.connectionState == ConnectionState.waiting
                            ? 'Loading sightings...'
                            : 'No identified sightings yet.\nIdentify photos in Activity to populate this profile.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade500, height: 1.6),
                      ),
                    ),
                  ),
                ),
              ],

              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        );
      },
    );
  }

  String _formatShortDate(DateTime dt) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month]} ${dt.day}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reassign Sheet — move a sighting to a different species
// ─────────────────────────────────────────────────────────────────────────────

class _ReassignSheet extends StatefulWidget {
  final _ProfileSighting ps;
  final String currentBirdId;

  const _ReassignSheet({required this.ps, required this.currentBirdId});

  @override
  State<_ReassignSheet> createState() => _ReassignSheetState();
}

class _ReassignSheetState extends State<_ReassignSheet> {
  final _searchController = TextEditingController();
  String _filter = '';
  bool _showNewField = false;
  final _newNameController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _searchController.dispose();
    _newNameController.dispose();
    super.dispose();
  }

  Future<void> _reassign(String newSpeciesName, String newCatalogBirdId) async {
    setState(() => _isLoading = true);
    try {
      final firestore = FirebaseFirestore.instance;
      final oldCatalogRef =
          firestore.collection(Bird.collectionPath).doc(widget.currentBirdId);
      final newCatalogRef =
          firestore.collection(Bird.collectionPath).doc(newCatalogBirdId);
      final sightingRef = firestore
          .collection(widget.ps.collectionPath)
          .doc(widget.ps.sighting.id);

      await firestore.runTransaction((txn) async {
        final newSnap = await txn.get(newCatalogRef);

        // Decrement old species count
        txn.update(oldCatalogRef, {'sightingCount': FieldValue.increment(-1)});

        // Create or increment new species
        if (newSnap.exists) {
          txn.update(newCatalogRef, {
            'sightingCount': FieldValue.increment(1),
            'lastSeen': FieldValue.serverTimestamp(),
          });
        } else {
          txn.set(
            newCatalogRef,
            Bird.createNewCatalogEntry(
              speciesName: newSpeciesName,
              imageStoragePath: widget.ps.sighting.imageUrl,
            ),
          );
        }

        // Update sighting doc
        txn.update(sightingRef, {
          'catalogBirdId': newCatalogBirdId,
          'speciesName': newSpeciesName,
        });
      });

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Moved to $newSpeciesName')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _createNew() async {
    final name = _newNameController.text.toTitleCase();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a species name.')));
      return;
    }
    await _reassign(name, name.toSlug());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, scrollController) => Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Move to species',
                style: TextStyle(
                    color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search species...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Icon(Icons.search, color: Colors.white54),
                  filled: true,
                  fillColor: Colors.grey.shade800,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: _filter.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.white54),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _filter = '');
                          },
                        )
                      : null,
                ),
                onChanged: (v) => setState(() => _filter = v.toLowerCase()),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection(Bird.collectionPath)
                    .orderBy('sightingCount', descending: true)
                    .limit(100)
                    .snapshots(),
                builder: (ctx, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final birds = snap.data!.docs
                      .map((d) => Bird.fromFirestore(d))
                      .where((b) =>
                          b.id != widget.currentBirdId &&
                          (_filter.isEmpty ||
                              b.commonName.toLowerCase().contains(_filter)))
                      .toList();

                  return ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: birds.length + 1,
                    itemBuilder: (ctx, i) {
                      if (i == birds.length) {
                        return _buildNewSpeciesFooter(theme);
                      }
                      final bird = birds[i];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: bird.primaryImageUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: bird.primaryImageUrl,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => const Icon(
                                      Icons.pets,
                                      color: Colors.grey,
                                      size: 36),
                                )
                              : const Icon(Icons.pets, color: Colors.grey, size: 36),
                        ),
                        title: Text(bird.commonName,
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            '${bird.sightingCount} sighting${bird.sightingCount != 1 ? 's' : ''}',
                            style:
                                const TextStyle(color: Colors.white54, fontSize: 12)),
                        trailing: _isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.chevron_right, color: Colors.white38),
                        onTap: _isLoading
                            ? null
                            : () => _reassign(bird.commonName, bird.id),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        hoverColor: Colors.white10,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNewSpeciesFooter(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: _showNewField
          ? Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newNameController,
                    style: const TextStyle(color: Colors.white),
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'e.g., American Robin',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.grey.shade800,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    onSubmitted: (_) => _createNew(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isLoading ? null : _createNew,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Create'),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => setState(() => _showNewField = false),
                ),
              ],
            )
          : OutlinedButton.icon(
              onPressed: () => setState(() => _showNewField = true),
              icon: const Icon(Icons.add),
              label: const Text('New species...'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white30),
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Photo Detail Screen — fullscreen viewer with side action panel
// ─────────────────────────────────────────────────────────────────────────────

class _PhotoDetailScreen extends StatefulWidget {
  final _ProfileSighting ps;
  final Bird bird;
  final VoidCallback onSetCover;
  final VoidCallback onReassign;
  final VoidCallback onUnidentify;

  const _PhotoDetailScreen({
    required this.ps,
    required this.bird,
    required this.onSetCover,
    required this.onReassign,
    required this.onUnidentify,
  });

  @override
  State<_PhotoDetailScreen> createState() => _PhotoDetailScreenState();
}

class _PhotoDetailScreenState extends State<_PhotoDetailScreen> {
  final _transformController = TransformationController();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  double _parseAspectRatio(String res) {
    final parts = res.split('x');
    if (parts.length == 2) {
      final w = double.tryParse(parts[0]);
      final h = double.tryParse(parts[1]);
      if (w != null && h != null && w > 0 && h > 0) return w / h;
    }
    return 16 / 9;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sighting = widget.ps.sighting;
    final aspectRatio = _parseAspectRatio(sighting.resolution);
    final t = sighting.timestamp;
    final timeStr =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}  '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Header bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.bird.commonName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.zoom_out_map, color: Colors.white),
                    onPressed: () => _transformController.value = Matrix4.identity(),
                    tooltip: 'Reset zoom',
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white24, height: 1),

            // Body: zoomable image left, actions right
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Zoomable image
                    Expanded(
                      flex: 2,
                      child: AspectRatio(
                        aspectRatio: aspectRatio,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.grey.shade900,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: theme.primaryColor.withValues(alpha: 0.6), width: 3),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: InteractiveViewer(
                              transformationController: _transformController,
                              boundaryMargin: EdgeInsets.zero,
                              minScale: 1.0,
                              maxScale: 5.0,
                              child: CachedNetworkImage(
                                imageUrl: sighting.imageUrl,
                                fit: BoxFit.contain,
                                placeholder: (_, __) => Center(
                                  child: CircularProgressIndicator(
                                      color: theme.primaryColor),
                                ),
                                errorWidget: (_, __, ___) => const Icon(
                                    Icons.image_not_supported,
                                    size: 80,
                                    color: Colors.grey),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 14),

                    // Right action panel
                    Expanded(
                      flex: 1,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade900,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _metaRow('Captured', timeStr),
                              _metaRow('Resolution', sighting.resolution),
                              const Divider(color: Colors.white24, height: 28),

                              // Set as cover
                              ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.pop(context);
                                  widget.onSetCover();
                                },
                                icon: const Icon(Icons.star),
                                label: const Text('Set as cover'),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  backgroundColor: theme.primaryColor,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Move to different species
                              OutlinedButton.icon(
                                onPressed: () {
                                  Navigator.pop(context);
                                  widget.onReassign();
                                },
                                icon: const Icon(Icons.swap_horiz),
                                label: const Text('Move species'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  foregroundColor: Colors.orange.shade300,
                                  side: BorderSide(color: Colors.orange.shade300),
                                ),
                              ),
                              const SizedBox(height: 28),

                              // Unidentify
                              OutlinedButton.icon(
                                onPressed: () {
                                  Navigator.pop(context);
                                  widget.onUnidentify();
                                },
                                icon: const Icon(Icons.undo),
                                label: const Text('Unidentify'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  foregroundColor: Colors.red.shade400,
                                  side: BorderSide(color: Colors.red.shade400),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cover Photo Card — contained photo, capped height
// ─────────────────────────────────────────────────────────────────────────────

class _CoverPhotoCard extends StatelessWidget {
  final Bird bird;
  final VoidCallback? onChangeCover;
  const _CoverPhotoCard({required this.bird, this.onChangeCover});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: SizedBox(
        height: 220,
        child: Card(
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              bird.primaryImageUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: bird.primaryImageUrl,
                      fit: BoxFit.contain,
                      placeholder: (_, __) => Container(color: Colors.grey.shade100),
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.pets, size: 64, color: Colors.grey),
                      ),
                    )
                  : Container(
                      color: theme.primaryColor.withValues(alpha: 0.08),
                      child: Icon(Icons.pets,
                          size: 72, color: theme.primaryColor.withValues(alpha: 0.3)),
                    ),
              if (onChangeCover != null)
                Positioned(
                  bottom: 10,
                  right: 10,
                  child: ElevatedButton.icon(
                    onPressed: onChangeCover,
                    icon: const Icon(Icons.photo_library, size: 15),
                    label: const Text('Change cover', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black54,
                      foregroundColor: Colors.white,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stat Card
// ─────────────────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _StatCard(
      {required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          child: Column(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(height: 6),
              Text(value,
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16, color: color)),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section header
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(title,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).primaryColor)),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Time of Day Bar Chart
// ─────────────────────────────────────────────────────────────────────────────

class _TimeOfDayChart extends StatelessWidget {
  final List<Sighting> sightings;
  const _TimeOfDayChart({required this.sightings});

  @override
  Widget build(BuildContext context) {
    final counts = List<int>.filled(24, 0);
    for (final s in sightings) {
      counts[s.timestamp.hour]++;
    }
    final maxCount = counts.reduce(math.max).toDouble();
    final bars = List.generate(
      24,
      (h) => BarChartGroupData(
        x: h,
        barRods: [
          BarChartRodData(
            toY: counts[h].toDouble(),
            color: Theme.of(context).primaryColor,
            width: 7,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          ),
        ],
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 1),
        boxShadow: [
          BoxShadow(color: Colors.grey.shade100, blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(8, 14, 12, 8),
      child: SizedBox(
        height: 160,
        child: BarChart(BarChartData(
          maxY: maxCount > 0 ? maxCount + 1 : 5,
          barGroups: bars,
          groupsSpace: 2,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: Colors.grey.shade200, strokeWidth: 1),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade300),
              left: BorderSide(color: Colors.grey.shade300),
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                interval: maxCount > 4 ? (maxCount / 4).ceilToDouble() : 1,
                getTitlesWidget: (v, _) => Text(v.toInt().toString(),
                    style: const TextStyle(fontSize: 9, color: Colors.grey)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 3,
                getTitlesWidget: (v, _) {
                  final h = v.toInt();
                  if (h % 3 != 0) return const SizedBox.shrink();
                  final lbl = h == 0
                      ? '12a'
                      : h < 12
                          ? '${h}a'
                          : h == 12
                              ? '12p'
                              : '${h - 12}p';
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(lbl,
                        style: const TextStyle(fontSize: 9, color: Colors.grey)),
                  );
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, _, rod, __) {
                final h = group.x;
                final lbl = h == 0
                    ? '12am'
                    : h < 12
                        ? '${h}am'
                        : h == 12
                            ? '12pm'
                            : '${h - 12}pm';
                return BarTooltipItem(
                  '$lbl\n${rod.toY.toInt()} sighting${rod.toY.toInt() != 1 ? 's' : ''}',
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              },
            ),
          ),
        )),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Time of Year Bar Chart
// ─────────────────────────────────────────────────────────────────────────────

class _TimeOfYearChart extends StatelessWidget {
  final List<Sighting> sightings;
  const _TimeOfYearChart({required this.sightings});

  int _dayOfYear(DateTime dt) => dt.difference(DateTime(dt.year, 1, 1)).inDays + 1;
  int _bucket(DateTime dt) => ((_dayOfYear(dt) - 1) / 14).floor().clamp(0, 25);

  @override
  Widget build(BuildContext context) {
    final counts = List<int>.filled(26, 0);
    for (final s in sightings) {
      counts[_bucket(s.timestamp)]++;
    }
    final maxCount = counts.reduce(math.max).toDouble();
    final bars = List.generate(
      26,
      (i) => BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: counts[i].toDouble(),
            color: Colors.green.shade500,
            width: 7,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          ),
        ],
      ),
    );
    const monthLabels = {0: 'Jan', 4: 'Mar', 8: 'May', 12: 'Jul', 17: 'Sep', 21: 'Nov'};

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 1),
        boxShadow: [
          BoxShadow(color: Colors.grey.shade100, blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(8, 14, 12, 8),
      child: SizedBox(
        height: 160,
        child: BarChart(BarChartData(
          maxY: maxCount > 0 ? maxCount + 1 : 5,
          barGroups: bars,
          groupsSpace: 2,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: Colors.grey.shade200, strokeWidth: 1),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade300),
              left: BorderSide(color: Colors.grey.shade300),
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                interval: maxCount > 4 ? (maxCount / 4).ceilToDouble() : 1,
                getTitlesWidget: (v, _) => Text(v.toInt().toString(),
                    style: const TextStyle(fontSize: 9, color: Colors.grey)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, _) {
                  final lbl = monthLabels[v.toInt()];
                  if (lbl == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(lbl,
                        style: const TextStyle(fontSize: 9, color: Colors.grey)),
                  );
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, _, rod, __) {
                final startDay = group.x * 14 + 1;
                const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
                final approxDate = DateTime(DateTime.now().year, 1, startDay);
                final monthStr = months[approxDate.month];
                return BarTooltipItem(
                  '$monthStr ~${approxDate.day}\n${rod.toY.toInt()} sighting${rod.toY.toInt() != 1 ? 's' : ''}',
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              },
            ),
          ),
        )),
      ),
    );
  }
}
