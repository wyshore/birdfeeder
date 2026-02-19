import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/sighting.dart';
import '../models/motion_instance.dart';
import '../models/bird.dart';
import '../config/firebase_paths.dart';
import '../utils/string_extensions.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Activity Screen — shows unidentified motion instances + snapshots, by day
// ─────────────────────────────────────────────────────────────────────────────

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  final Set<String> _selectedIds = {};
  bool _isSelectionMode = false;
  bool _isRefreshing = false;

  late final Stream<List<_ActivityItem>> _unidentifiedStream;

  @override
  void initState() {
    super.initState();
    _unidentifiedStream = _buildMergedStream();
  }

  Stream<List<_ActivityItem>> _buildMergedStream() {
    final firestore = FirebaseFirestore.instance;

    // New motion instances — Pi v2 writes snake_case (is_identified)
    final instanceStream = firestore
        .collection(LogPaths.motionCaptures)
        .where('is_identified', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .limit(100)
        .snapshots()
        .map((s) => s.docs
            .map((d) => _InstanceItem(MotionInstance.fromFirestore(d)))
            .toList() as List<_ActivityItem>);

    // Legacy motion captures — old format uses camelCase (isIdentified)
    final legacyMotionStream = firestore
        .collection(LogPaths.motionCaptures)
        .where('isIdentified', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .limit(100)
        .snapshots()
        .map((s) => s.docs
            .map((d) => _SnapshotItem(
                  Sighting.fromFirestore(d),
                  collectionPath: LogPaths.motionCaptures,
                  tileLabel: 'Old Capture',
                ))
            .toList() as List<_ActivityItem>);

    // Manual snapshots — camera_server writes camelCase (isIdentified)
    final snapshotStream = firestore
        .collection(LogPaths.snapshots)
        .where('isIdentified', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .limit(50)
        .snapshots()
        .map((s) => s.docs
            .map((d) => _SnapshotItem(Sighting.fromFirestore(d)))
            .toList() as List<_ActivityItem>);

    return _combineAll([instanceStream, legacyMotionStream, snapshotStream]);
  }

  Stream<List<_ActivityItem>> _combineAll(
    List<Stream<List<_ActivityItem>>> streams,
  ) {
    final controller = StreamController<List<_ActivityItem>>();
    final latest = List<List<_ActivityItem>?>.filled(streams.length, null);
    final subs = <StreamSubscription<List<_ActivityItem>>>[];

    void emit() {
      if (latest.every((l) => l != null)) {
        final combined = latest.expand((l) => l!).toList();
        combined.sort((x, y) => y.timestamp.compareTo(x.timestamp));
        controller.add(combined);
      }
    }

    for (var i = 0; i < streams.length; i++) {
      final idx = i;
      subs.add(streams[idx].listen(
        (data) { latest[idx] = data; emit(); },
        onError: controller.addError,
      ));
    }
    controller.onCancel = () { for (final s in subs) { s.cancel(); } };
    return controller.stream;
  }

  // ── Selection ──────────────────────────────────────────────────────────────

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

  Future<void> _deleteSelected(List<_ActivityItem> allItems) async {
    final toDelete = allItems.where((i) => _selectedIds.contains(i.id)).toList();
    if (toDelete.isEmpty) return;

    setState(() {
      _selectedIds.clear();
      _isSelectionMode = false;
    });

    final firestore = FirebaseFirestore.instance;
    final storage = FirebaseStorage.instance;

    try {
      for (final item in toDelete) {
        if (item is _InstanceItem) {
          for (final path in item.instance.storagePaths) {
            if (path.isNotEmpty) {
              try { await storage.ref(path).delete(); } catch (_) {}
            }
          }
          await firestore.collection(LogPaths.motionCaptures).doc(item.id).delete();
        } else if (item is _SnapshotItem) {
          final path = item.sighting.storagePath;
          if (path.isNotEmpty) {
            try { await storage.ref(path).delete(); } catch (_) {}
          }
          await firestore.collection(item.collectionPath).doc(item.id).delete();
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted ${toDelete.length} item(s).')),
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

  // ── Clear all items for a day ──────────────────────────────────────────────

  Future<void> _clearDay(_DayGroup group) async {
    final count = group.items.length;
    final dayLabel = _formatDayHeader(group.dateKey);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear $dayLabel?'),
        content: Text(
          'This will permanently delete $count item${count != 1 ? 's' : ''} from $dayLabel, '
          'including all images. This cannot be undone.',
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

    try {
      for (final item in group.items) {
        if (item is _InstanceItem) {
          for (final path in item.instance.storagePaths) {
            if (path.isNotEmpty) {
              try { await storage.ref(path).delete(); } catch (_) {}
            }
          }
          await firestore.collection(LogPaths.motionCaptures).doc(item.id).delete();
        } else if (item is _SnapshotItem) {
          final path = item.sighting.storagePath;
          if (path.isNotEmpty) {
            try { await storage.ref(path).delete(); } catch (_) {}
          }
          await firestore.collection(item.collectionPath).doc(item.id).delete();
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cleared $count item${count != 1 ? 's' : ''} from $dayLabel.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Clear failed: $e')));
      }
    }
  }

  // ── Open detail ────────────────────────────────────────────────────────────

  void _openDetail(_ActivityItem item) {
    if (_isSelectionMode) return;
    Widget detailScreen;
    if (item is _InstanceItem) {
      detailScreen = _InstanceDetailScreen(item: item);
    } else if (item is _SnapshotItem) {
      detailScreen = _SightingDetailScreen(item: item);
    } else {
      return;
    }
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      barrierDismissible: true,
      barrierLabel: 'Close',
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (ctx, a1, a2) => detailScreen,
      transitionBuilder: (ctx, a1, a2, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(a1),
        child: child,
      ),
    );
  }

  // ── Group by date ──────────────────────────────────────────────────────────

  List<_DayGroup> _groupByDay(List<_ActivityItem> items) {
    final Map<String, List<_ActivityItem>> map = {};
    for (final item in items) {
      final t = item.timestamp;
      final key = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      map.putIfAbsent(key, () => []).add(item);
    }
    final groups = map.entries
        .map((e) => _DayGroup(dateKey: e.key, items: e.value))
        .toList()
      ..sort((a, b) => b.dateKey.compareTo(a.dateKey));
    return groups;
  }

  Future<void> _requestBatchUpload() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await FirebaseFirestore.instance
          .doc(StatusPaths.batchUploadRequest)
          .set({'requested': true});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Upload requested — new captures will appear shortly.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to request upload: $e')));
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
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
          else ...[
            _isRefreshing
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.cloud_sync),
                    onPressed: _requestBatchUpload,
                    tooltip: 'Fetch new captures from Pi',
                  ),
            IconButton(
              icon: const Icon(Icons.select_all),
              onPressed: () => _toggleSelectionMode(true),
              tooltip: 'Select',
            ),
          ],
        ],
      ),
      body: StreamBuilder<List<_ActivityItem>>(
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
                  // ── Day header ──────────────────────────────────────────
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
                            color: Theme.of(context).primaryColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${group.items.length}',
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

                  // ── Items list ──────────────────────────────────────────
                  ...group.items.map((item) {
                    final isSelected = _selectedIds.contains(item.id);
                    if (item is _InstanceItem) {
                      return _InstanceTile(
                        item: item,
                        isSelected: isSelected,
                        isSelectionMode: _isSelectionMode,
                        onTap: () => _isSelectionMode
                            ? _toggleSelection(item.id)
                            : _openDetail(item),
                        onLongPress: () {
                          if (!_isSelectionMode) _toggleSelectionMode(true);
                          _toggleSelection(item.id);
                        },
                      );
                    } else if (item is _SnapshotItem) {
                      return _SnapshotTile(
                        item: item,
                        isSelected: isSelected,
                        isSelectionMode: _isSelectionMode,
                        onTap: () => _isSelectionMode
                            ? _toggleSelection(item.id)
                            : _openDetail(item),
                        onLongPress: () {
                          if (!_isSelectionMode) _toggleSelectionMode(true);
                          _toggleSelection(item.id);
                        },
                      );
                    }
                    return const SizedBox.shrink();
                  }),
                  const SizedBox(height: 8),
                ],
              );
            },
          );
        },
      ),
      floatingActionButton: _isSelectionMode && _selectedIds.isNotEmpty
          ? StreamBuilder<List<_ActivityItem>>(
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
// Activity item types
// ─────────────────────────────────────────────────────────────────────────────

abstract class _ActivityItem {
  String get id;
  DateTime get timestamp;
}

class _InstanceItem implements _ActivityItem {
  final MotionInstance instance;
  @override String get id => instance.id;
  @override DateTime get timestamp => instance.timestamp;
  _InstanceItem(this.instance);
}

class _SnapshotItem implements _ActivityItem {
  final Sighting sighting;
  final String collectionPath;
  final String tileLabel;
  @override String get id => sighting.id;
  @override DateTime get timestamp => sighting.timestamp;
  _SnapshotItem(this.sighting, {
    this.collectionPath = LogPaths.snapshots,
    this.tileLabel = 'Manual Snapshot',
  });
}

class _DayGroup {
  final String dateKey;
  final List<_ActivityItem> items;
  _DayGroup({required this.dateKey, required this.items});
}

// ─────────────────────────────────────────────────────────────────────────────
// Motion Instance Tile
// ─────────────────────────────────────────────────────────────────────────────

class _InstanceTile extends StatelessWidget {
  final _InstanceItem item;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _InstanceTile({
    required this.item,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final instance = item.instance;
    final t = instance.timestamp;
    final timeStr = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final durationStr = '${instance.motionDuration.toStringAsFixed(1)}s';
    final isVideo = instance.isVideo;
    final countLabel = isVideo
        ? 'Video'
        : '${instance.fileCount} photo${instance.fileCount != 1 ? 's' : ''}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: isSelected ? 4 : 2,
      color: isSelected ? theme.primaryColor.withValues(alpha: 0.08) : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // Thumbnail
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: instance.thumbnailUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: instance.thumbnailUrl,
                            width: 72, height: 72,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(
                              width: 72, height: 72,
                              color: Colors.grey.shade200,
                              child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                            ),
                            errorWidget: (_, __, ___) => Container(
                              width: 72, height: 72,
                              color: Colors.grey.shade200,
                              child: const Icon(Icons.image_not_supported, color: Colors.grey),
                            ),
                          )
                        : Container(
                            width: 72, height: 72,
                            color: Colors.grey.shade200,
                            child: const Icon(Icons.image, color: Colors.grey),
                          ),
                  ),
                  if (isVideo)
                    Positioned(
                      bottom: 2, right: 2,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade700.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(Icons.videocam, color: Colors.white, size: 14),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),

              // Metadata
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      timeStr,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.timer_outlined, size: 14, color: Colors.grey.shade600),
                        const SizedBox(width: 4),
                        Text(
                          'Motion: $durationStr',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: isVideo
                            ? Colors.blue.shade50
                            : theme.primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        countLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isVideo ? Colors.blue.shade700 : theme.primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Selection or chevron
              if (isSelectionMode)
                Container(
                  width: 24, height: 24,
                  decoration: BoxDecoration(
                    color: isSelected ? theme.primaryColor : Colors.black26,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Icon(
                    isSelected ? Icons.check : null,
                    color: Colors.white, size: 14,
                  ),
                )
              else
                const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Snapshot Tile
// ─────────────────────────────────────────────────────────────────────────────

class _SnapshotTile extends StatelessWidget {
  final _SnapshotItem item;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _SnapshotTile({
    required this.item,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sighting = item.sighting;
    final t = sighting.timestamp;
    final timeStr = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: isSelected ? 4 : 2,
      color: isSelected ? theme.primaryColor.withValues(alpha: 0.08) : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: sighting.imageUrl,
                  width: 72, height: 72,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    width: 72, height: 72,
                    color: Colors.grey.shade200,
                    child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 72, height: 72,
                    color: Colors.grey.shade200,
                    child: const Icon(Icons.image_not_supported, color: Colors.grey),
                  ),
                ),
              ),
              const SizedBox(width: 14),

              // Metadata
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      timeStr,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        item.tileLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.amber.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Selection or chevron
              if (isSelectionMode)
                Container(
                  width: 24, height: 24,
                  decoration: BoxDecoration(
                    color: isSelected ? theme.primaryColor : Colors.black26,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Icon(
                    isSelected ? Icons.check : null,
                    color: Colors.white, size: 14,
                  ),
                )
              else
                const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Instance Detail Screen
// ─────────────────────────────────────────────────────────────────────────────

class _InstanceDetailScreen extends StatefulWidget {
  final _InstanceItem item;
  const _InstanceDetailScreen({required this.item});

  @override
  State<_InstanceDetailScreen> createState() => _InstanceDetailScreenState();
}

class _InstanceDetailScreenState extends State<_InstanceDetailScreen> {
  bool _isLoading = false;
  int _currentPhotoIndex = 0;
  final _transformController = TransformationController();

  MotionInstance get _instance => widget.item.instance;

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this sighting?'),
        content: Text(
          'This will permanently remove ${_instance.fileCount} '
          '${_instance.isVideo ? 'video' : 'photo${_instance.fileCount != 1 ? 's' : ''}'} '
          'and the log entry.',
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

    setState(() => _isLoading = true);
    try {
      final storage = FirebaseStorage.instance;
      for (final path in _instance.storagePaths) {
        if (path.isNotEmpty) {
          try { await storage.ref(path).delete(); } catch (_) {}
        }
      }
      await FirebaseFirestore.instance
          .collection(LogPaths.motionCaptures)
          .doc(_instance.id)
          .delete();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        setState(() => _isLoading = false);
      }
    }
  }

  void _openSpeciesPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SpeciesPickerSheet(
        itemId: _instance.id,
        imageUrl: _instance.thumbnailUrl,
        collectionPath: LogPaths.motionCaptures,
        useSnakeCase: true, // Pi writes snake_case for instances
        onIdentified: () {
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = _instance.timestamp;
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
                      'Identify This Sighting',
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (!_instance.isVideo)
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

            // Body: viewer left, panel right
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left: photo viewer or video placeholder
                    Expanded(
                      flex: 2,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade900,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: theme.primaryColor.withValues(alpha: 0.6), width: 3),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: _instance.isVideo
                              ? _buildVideoPlaceholder(theme)
                              : _buildPhotoViewer(theme),
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
                                  color: theme.primaryColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'Motion Capture',
                                  style: TextStyle(
                                    color: theme.primaryColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),

                              const SizedBox(height: 14),
                              _metaRow('Captured', timeStr),
                              _metaRow('Duration', '${_instance.motionDuration.toStringAsFixed(1)}s'),
                              _metaRow('Mode', _instance.captureMode == 'video' ? 'Video' : 'Photo burst'),
                              _metaRow(
                                _instance.isVideo ? 'Recording' : 'Photos',
                                _instance.isVideo ? '1 video' : '${_instance.fileCount}',
                              ),
                              if (_instance.resolution.isNotEmpty)
                                _metaRow('Resolution', _instance.resolution),

                              const Divider(color: Colors.white24, height: 28),

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

  Widget _buildPhotoViewer(ThemeData theme) {
    if (_instance.imageUrls.isEmpty) {
      return const Center(
        child: Icon(Icons.image_not_supported, size: 80, color: Colors.grey),
      );
    }
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            itemCount: _instance.imageUrls.length,
            onPageChanged: (i) => setState(() {
              _currentPhotoIndex = i;
              _transformController.value = Matrix4.identity();
            }),
            itemBuilder: (ctx, i) => InteractiveViewer(
              transformationController: i == _currentPhotoIndex ? _transformController : null,
              boundaryMargin: EdgeInsets.zero,
              minScale: 1.0,
              maxScale: 5.0,
              child: CachedNetworkImage(
                imageUrl: _instance.imageUrls[i],
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
        if (_instance.fileCount > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Photo ${_currentPhotoIndex + 1} of ${_instance.fileCount}',
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _buildVideoPlaceholder(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam, size: 72, color: Colors.blue.shade300),
          const SizedBox(height: 12),
          const Text(
            'Video recording',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'In-app video playback coming soon.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
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
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white))),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Snapshot Detail Screen
// ─────────────────────────────────────────────────────────────────────────────

class _SightingDetailScreen extends StatefulWidget {
  final _SnapshotItem item;
  const _SightingDetailScreen({required this.item});

  @override
  State<_SightingDetailScreen> createState() => _SightingDetailScreenState();
}

class _SightingDetailScreenState extends State<_SightingDetailScreen> {
  bool _isLoading = false;
  final _transformController = TransformationController();

  Sighting get _sighting => widget.item.sighting;

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
          .collection(widget.item.collectionPath)
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

  void _openSpeciesPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SpeciesPickerSheet(
        itemId: _sighting.id,
        imageUrl: _sighting.imageUrl,
        collectionPath: widget.item.collectionPath,
        useSnakeCase: false, // snapshots and legacy captures both use camelCase
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: const Text(
                      'Identify This Sighting',
                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
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
                            border: Border.all(color: theme.primaryColor.withValues(alpha: 0.6), width: 3),
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
                                placeholder: (_, __) =>
                                    Center(child: CircularProgressIndicator(color: theme.primaryColor)),
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
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade700.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  widget.item.tileLabel,
                                  style: TextStyle(
                                    color: Colors.amber.shade400,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              _metaRow('Captured', timeStr),
                              _metaRow('Resolution', _sighting.resolution),
                              const Divider(color: Colors.white24, height: 28),
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
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white))),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Species Picker Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _SpeciesPickerSheet extends StatefulWidget {
  final String itemId;
  final String imageUrl;
  final String collectionPath;
  final bool useSnakeCase; // true for motion instances, false for snapshots
  final VoidCallback onIdentified;

  const _SpeciesPickerSheet({
    required this.itemId,
    required this.imageUrl,
    required this.collectionPath,
    required this.useSnakeCase,
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
      final itemRef = firestore.collection(widget.collectionPath).doc(widget.itemId);

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
            imageStoragePath: widget.imageUrl,
          ));
        }

        // Update sighting/instance with the correct field names
        if (widget.useSnakeCase) {
          txn.update(itemRef, {
            'is_identified': true,
            'catalog_bird_id': catalogBirdId,
            'species_name': speciesName,
          });
        } else {
          txn.update(itemRef, {
            'isIdentified': true,
            'catalogBirdId': catalogBirdId,
            'speciesName': speciesName,
          });
        }
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
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Identify this sighting',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
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
                    itemCount: birds.length + 1,
                    itemBuilder: (ctx, i) {
                      if (i == birds.length) return _buildNewSpeciesFooter(theme);
                      final bird = birds[i];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: bird.primaryImageUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: bird.primaryImageUrl,
                                  width: 48, height: 48, fit: BoxFit.cover,
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
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
