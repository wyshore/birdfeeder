import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/sighting.dart';
import '../models/bird.dart';
import '../config/firebase_paths.dart';
import '../utils/string_extensions.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Activity Screen — shows all unidentified sightings, grouped by day
// ─────────────────────────────────────────────────────────────────────────────

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  // Selection state
  final Set<String> _selectedIds = {};
  bool _isSelectionMode = false;

  // Merged stream from both collections
  late final Stream<List<_TaggedSighting>> _unidentifiedStream;

  @override
  void initState() {
    super.initState();
    _unidentifiedStream = _buildMergedStream();
  }

  Stream<List<_TaggedSighting>> _buildMergedStream() {
    final firestore = FirebaseFirestore.instance;

    final motionStream = firestore
        .collection(LogPaths.motionCaptures)
        .where('isIdentified', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .limit(100)
        .snapshots()
        .map((s) => s.docs
            .map((d) => _TaggedSighting(Sighting.fromFirestore(d), 'motion_capture', LogPaths.motionCaptures))
            .toList());

    final snapshotStream = firestore
        .collection(LogPaths.snapshots)
        .where('isIdentified', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .limit(50)
        .snapshots()
        .map((s) => s.docs
            .map((d) => _TaggedSighting(Sighting.fromFirestore(d), 'snapshot', LogPaths.snapshots))
            .toList());

    // Merge the two streams by combining latest values
    return _combineLatest(motionStream, snapshotStream);
  }

  Stream<List<_TaggedSighting>> _combineLatest(
    Stream<List<_TaggedSighting>> a,
    Stream<List<_TaggedSighting>> b,
  ) {
    final controller = StreamController<List<_TaggedSighting>>();
    List<_TaggedSighting>? latestA;
    List<_TaggedSighting>? latestB;

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

  // ── Selection helpers ──────────────────────────────────────────────────────

  void _toggleSelectionMode(bool value) {
    setState(() {
      _isSelectionMode = value;
      if (!value) _selectedIds.clear();
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _isSelectionMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  // ── Delete selected ────────────────────────────────────────────────────────

  Future<void> _deleteSelected(List<_TaggedSighting> allSightings) async {
    final toDelete = allSightings.where((s) => _selectedIds.contains(s.sighting.id)).toList();
    if (toDelete.isEmpty) return;

    setState(() {
      _selectedIds.clear();
      _isSelectionMode = false;
    });

    final firestore = FirebaseFirestore.instance;
    final storage = FirebaseStorage.instance;
    final batch = firestore.batch();

    try {
      for (final tagged in toDelete) {
        final docRef = firestore.collection(tagged.collectionPath).doc(tagged.sighting.id);
        batch.delete(docRef);
        final path = tagged.sighting.storagePath;
        if (path.isNotEmpty) {
          try { await storage.ref(path).delete(); } catch (_) {}
        }
      }
      await batch.commit();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted ${toDelete.length} sighting(s).')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  // ── Clear all sightings for a day ─────────────────────────────────────────

  Future<void> _clearDay(_DayGroup group) async {
    final count = group.sightings.length;
    final dayLabel = _formatDayHeader(group.dateKey);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear $dayLabel?'),
        content: Text(
          'This will permanently delete all $count photo${count != 1 ? 's' : ''} from $dayLabel, '
          'including their images in storage. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete All', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final firestore = FirebaseFirestore.instance;
    final storage = FirebaseStorage.instance;
    final batch = firestore.batch();

    try {
      for (final tagged in group.sightings) {
        batch.delete(firestore.collection(tagged.collectionPath).doc(tagged.sighting.id));
        final path = tagged.sighting.storagePath;
        if (path.isNotEmpty) {
          try { await storage.ref(path).delete(); } catch (_) {}
        }
      }
      await batch.commit();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cleared $count sighting${count != 1 ? 's' : ''} from $dayLabel.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Clear failed: $e')));
      }
    }
  }

  // ── Open detail dialog ─────────────────────────────────────────────────────

  void _openDetail(_TaggedSighting tagged) {
    if (_isSelectionMode) return;
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      barrierDismissible: true,
      barrierLabel: 'Close',
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (ctx, a1, a2) => _SightingDetailScreen(tagged: tagged),
      transitionBuilder: (ctx, a1, a2, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(a1),
        child: child,
      ),
    );
  }

  // ── Group by date ──────────────────────────────────────────────────────────

  List<_DayGroup> _groupByDay(List<_TaggedSighting> sightings) {
    final Map<String, List<_TaggedSighting>> map = {};
    for (final s in sightings) {
      final t = s.sighting.timestamp;
      final key = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      map.putIfAbsent(key, () => []).add(s);
    }
    final groups = map.entries
        .map((e) => _DayGroup(dateKey: e.key, sightings: e.value))
        .toList()
      ..sort((a, b) => b.dateKey.compareTo(a.dateKey));
    return groups;
  }

  String _formatDayHeader(String dateKey) {
    final parts = dateKey.split('-');
    final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final date = DateTime(dt.year, dt.month, dt.day);
    if (date == today) return 'Today';
    if (date == yesterday) return 'Yesterday';
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isSelectionMode ? 'Select (${_selectedIds.length})' : 'Activity',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
        actions: [
          if (_isSelectionMode)
            TextButton(
              onPressed: () => _toggleSelectionMode(false),
              child: const Text('Done', style: TextStyle(color: Colors.white)),
            )
          else
            IconButton(
              icon: const Icon(Icons.select_all),
              onPressed: () => _toggleSelectionMode(true),
              tooltip: 'Select',
            ),
        ],
      ),
      body: StreamBuilder<List<_TaggedSighting>>(
        stream: _unidentifiedStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final all = snapshot.data!;

          if (all.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 72, color: Colors.green.shade400),
                  const SizedBox(height: 16),
                  const Text('All caught up!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('No unidentified sightings.', style: TextStyle(color: Colors.grey.shade600)),
                ],
              ),
            );
          }

          final groups = _groupByDay(all);

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: groups.length,
            itemBuilder: (context, groupIndex) {
              final group = groups[groupIndex];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Day header ────────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: Row(
                      children: [
                        Text(
                          _formatDayHeader(group.dateKey),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor.withValues(alpha:0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${group.sightings.length}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => _clearDay(group),
                          icon: const Icon(Icons.delete_sweep, size: 16),
                          label: const Text('Clear day', style: TextStyle(fontSize: 12)),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red.shade400,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── Photo grid ────────────────────────────────────────────
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      crossAxisSpacing: 6,
                      mainAxisSpacing: 6,
                      childAspectRatio: 1.0,
                    ),
                    itemCount: group.sightings.length,
                    itemBuilder: (ctx, i) {
                      final tagged = group.sightings[i];
                      final isSelected = _selectedIds.contains(tagged.sighting.id);
                      return _ActivityTile(
                        tagged: tagged,
                        isSelected: isSelected,
                        isSelectionMode: _isSelectionMode,
                        onTap: () {
                          if (_isSelectionMode) {
                            _toggleSelection(tagged.sighting.id);
                          } else {
                            _openDetail(tagged);
                          }
                        },
                        onLongPress: () {
                          if (!_isSelectionMode) _toggleSelectionMode(true);
                          _toggleSelection(tagged.sighting.id);
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          );
        },
      ),
      floatingActionButton: _isSelectionMode && _selectedIds.isNotEmpty
          ? StreamBuilder<List<_TaggedSighting>>(
              stream: _unidentifiedStream,
              builder: (ctx, snap) => FloatingActionButton.extended(
                onPressed: snap.hasData ? () => _deleteSelected(snap.data!) : null,
                label: Text('Delete (${_selectedIds.length})'),
                icon: const Icon(Icons.delete),
                backgroundColor: Colors.red,
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Data helpers
// ─────────────────────────────────────────────────────────────────────────────

class _TaggedSighting {
  final Sighting sighting;
  final String type; // 'motion_capture' | 'snapshot'
  final String collectionPath;
  _TaggedSighting(this.sighting, this.type, this.collectionPath);
  bool get isSnapshot => type == 'snapshot';
}

class _DayGroup {
  final String dateKey;
  final List<_TaggedSighting> sightings;
  _DayGroup({required this.dateKey, required this.sightings});
}

// ─────────────────────────────────────────────────────────────────────────────
// Activity Tile
// ─────────────────────────────────────────────────────────────────────────────

class _ActivityTile extends StatelessWidget {
  final _TaggedSighting tagged;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ActivityTile({
    required this.tagged,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: tagged.sighting.imageUrl,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                color: Colors.grey.shade200,
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              errorWidget: (_, __, ___) => Container(
                color: Colors.grey.shade200,
                child: const Icon(Icons.image_not_supported, color: Colors.grey),
              ),
            ),
          ),

          // Snapshot badge (top-left)
          if (tagged.isSnapshot)
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.shade700.withValues(alpha:0.9),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Snap',
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
            ),

          // Selection overlay
          if (isSelectionMode)
            Container(
              decoration: BoxDecoration(
                color: isSelected ? theme.primaryColor.withValues(alpha:0.25) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: isSelected ? Border.all(color: theme.primaryColor, width: 2.5) : null,
              ),
            ),

          // Selection check
          if (isSelectionMode)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: isSelected ? theme.primaryColor : Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Icon(
                  isSelected ? Icons.check : null,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sighting Detail Screen
// ─────────────────────────────────────────────────────────────────────────────

class _SightingDetailScreen extends StatefulWidget {
  final _TaggedSighting tagged;
  const _SightingDetailScreen({required this.tagged});

  @override
  State<_SightingDetailScreen> createState() => _SightingDetailScreenState();
}

class _SightingDetailScreenState extends State<_SightingDetailScreen> {
  bool _isLoading = false;
  final _transformController = TransformationController();

  Sighting get _sighting => widget.tagged.sighting;

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
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete sighting?'),
        content: const Text('This will remove the photo and log entry permanently.'),
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

    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance
          .collection(widget.tagged.collectionPath)
          .doc(_sighting.id)
          .delete();
      if (_sighting.storagePath.isNotEmpty) {
        await FirebaseStorage.instance.ref(_sighting.storagePath).delete();
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        setState(() => _isLoading = false);
      }
    }
  }

  // ── Open species picker ────────────────────────────────────────────────────

  void _openSpeciesPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SpeciesPickerSheet(
        sightingId: _sighting.id,
        sightingImageUrl: _sighting.imageUrl,
        collectionPath: widget.tagged.collectionPath,
        onIdentified: () {
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final aspectRatio = _parseAspectRatio(_sighting.resolution);
    final t = _sighting.timestamp;
    final timeStr =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}  '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final typeLabel = widget.tagged.isSnapshot ? 'Manual Snapshot' : 'Motion Capture';

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
                      'Identify This Sighting',
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

            // Body: image left, panel right
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
                            border: Border.all(color: theme.primaryColor.withValues(alpha:0.6), width: 3),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: InteractiveViewer(
                              transformationController: _transformController,
                              boundaryMargin: EdgeInsets.zero,
                              minScale: 1.0,
                              maxScale: 5.0,
                              child: CachedNetworkImage(
                                imageUrl: _sighting.imageUrl,
                                fit: BoxFit.contain,
                                placeholder: (_, __) => Center(
                                  child: CircularProgressIndicator(color: theme.primaryColor),
                                ),
                                errorWidget: (_, __, ___) =>
                                    const Icon(Icons.image_not_supported, size: 80, color: Colors.grey),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 14),

                    // Right panel
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
                              // Source badge
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: widget.tagged.isSnapshot
                                      ? Colors.amber.shade700.withValues(alpha:0.2)
                                      : theme.primaryColor.withValues(alpha:0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  typeLabel,
                                  style: TextStyle(
                                    color: widget.tagged.isSnapshot
                                        ? Colors.amber.shade400
                                        : theme.primaryColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),

                              const SizedBox(height: 14),
                              _metaRow('Captured', timeStr),
                              _metaRow('Resolution', _sighting.resolution),

                              const Divider(color: Colors.white24, height: 28),

                              // Identify button
                              ElevatedButton.icon(
                                onPressed: _isLoading ? null : _openSpeciesPicker,
                                icon: const Icon(Icons.search),
                                label: const Text('Identify as...', style: TextStyle(fontSize: 16)),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  backgroundColor: theme.primaryColor,
                                  foregroundColor: Colors.white,
                                ),
                              ),

                              const SizedBox(height: 28),

                              // Delete button
                              OutlinedButton.icon(
                                onPressed: _isLoading ? null : _delete,
                                icon: const Icon(Icons.delete_forever),
                                label: const Text('No bird? Delete'),
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
            width: 90,
            child: Text(label, style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w500)),
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
// Species Picker Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _SpeciesPickerSheet extends StatefulWidget {
  final String sightingId;
  final String sightingImageUrl;
  final String collectionPath;
  final VoidCallback onIdentified;

  const _SpeciesPickerSheet({
    required this.sightingId,
    required this.sightingImageUrl,
    required this.collectionPath,
    required this.onIdentified,
  });

  @override
  State<_SpeciesPickerSheet> createState() => _SpeciesPickerSheetState();
}

class _SpeciesPickerSheetState extends State<_SpeciesPickerSheet> {
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

  Future<void> _identify(String speciesName, String catalogBirdId) async {
    setState(() => _isLoading = true);
    try {
      final firestore = FirebaseFirestore.instance;
      final catalogRef = firestore.collection(Bird.collectionPath).doc(catalogBirdId);
      final sightingRef = firestore.collection(widget.collectionPath).doc(widget.sightingId);

      await firestore.runTransaction((txn) async {
        final catalogSnap = await txn.get(catalogRef);

        if (catalogSnap.exists) {
          txn.update(catalogRef, {
            'sightingCount': FieldValue.increment(1),
            'lastSeen': FieldValue.serverTimestamp(),
          });
        } else {
          txn.set(catalogRef, Bird.createNewCatalogEntry(
            speciesName: speciesName,
            imageStoragePath: widget.sightingImageUrl,
          ));
        }

        txn.update(sightingRef, {
          'isIdentified': true,
          'catalogBirdId': catalogBirdId,
          'speciesName': speciesName,
        });
      });

      if (mounted) {
        Navigator.pop(context);
        widget.onIdentified();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Identified as $speciesName')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to identify: $e')));
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
    await _identify(name, name.toSlug());
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
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Identify this sighting',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Search field
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

            // Species list
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection(Bird.collectionPath)
                    .orderBy('sightingCount', descending: true)
                    .limit(100)
                    .snapshots(),
                builder: (ctx, snap) {
                  if (snap.hasError) {
                    return Center(child: Text('Error: ${snap.error}', style: const TextStyle(color: Colors.white)));
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final birds = snap.data!.docs
                      .map((d) => Bird.fromFirestore(d))
                      .where((b) => _filter.isEmpty || b.commonName.toLowerCase().contains(_filter))
                      .toList();

                  return ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: birds.length + 1, // +1 for "New species" footer
                    itemBuilder: (ctx, i) {
                      if (i == birds.length) {
                        // Footer: create new
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
                                  errorWidget: (_, __, ___) =>
                                      const Icon(Icons.pets, color: Colors.grey, size: 36),
                                )
                              : const Icon(Icons.pets, color: Colors.grey, size: 36),
                        ),
                        title: Text(
                          bird.commonName,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${bird.sightingCount} sighting${bird.sightingCount != 1 ? 's' : ''}',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        trailing: _isLoading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.chevron_right, color: Colors.white38),
                        onTap: _isLoading ? null : () => _identify(bird.commonName, bird.id),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  child: _isLoading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              ),
            ),
    );
  }
}
