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

  @override
  void initState() {
    super.initState();
    _bird = widget.bird;
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

  Future<void> _deleteSpecies(List<Sighting> sightings) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Species?'),
        content: Text(
          'This will remove "${_bird.commonName}" from the catalog and unlink '
          '${sightings.length} sighting${sightings.length != 1 ? 's' : ''}. '
          'Photos will not be deleted.',
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
      for (final s in sightings) {
        batch.update(
          firestore.collection(LogPaths.motionCaptures).doc(s.id),
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

  // ── Photo tap: view or set cover ───────────────────────────────────────────

  void _onPhotoTap(Sighting sighting) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.fullscreen),
              title: const Text('View fullscreen'),
              onTap: () {
                Navigator.pop(ctx);
                _viewFullscreen(sighting.imageUrl);
              },
            ),
            ListTile(
              leading: const Icon(Icons.star),
              title: const Text('Set as cover photo'),
              onTap: () {
                Navigator.pop(ctx);
                _setCoverPhoto(sighting.imageUrl);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _viewFullscreen(String imageUrl) {
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.95),
      barrierDismissible: true,
      barrierLabel: 'Close',
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, a1, a2) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        child: Center(
          child: InteractiveViewer(
            child: CachedNetworkImage(imageUrl: imageUrl, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  void _showCoverPicker(List<Sighting> sightings) {
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
                itemCount: sightings.length,
                itemBuilder: (_, i) {
                  final s = sightings[i];
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _setCoverPhoto(s.imageUrl);
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(imageUrl: s.imageUrl, fit: BoxFit.cover),
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

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(LogPaths.motionCaptures)
          .where('catalogBirdId', isEqualTo: _bird.id)
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        final sightings = snapshot.hasData
            ? snapshot.data!.docs.map((d) => Sighting.fromFirestore(d)).toList()
            : <Sighting>[];

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
                onPressed: () => _deleteSpecies(sightings),
              ),
            ],
          ),
          body: CustomScrollView(
            slivers: [
              // ── Cover photo card (contained, not cropped) ─────────────────
              SliverToBoxAdapter(
                child: _CoverPhotoCard(
                  bird: _bird,
                  onChangeCover: sightings.isEmpty ? null : () => _showCoverPicker(sightings),
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

              // ── Photo grid ────────────────────────────────────────────────
              if (sightings.isNotEmpty) ...[
                _SectionHeader(title: 'All Sightings (${sightings.length})'),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final s = sightings[i];
                        final isCover = s.imageUrl == _bird.primaryImageUrl;
                        return GestureDetector(
                          onTap: () => _onPhotoTap(s),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(
                                  imageUrl: s.imageUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => Container(color: Colors.grey.shade200),
                                  errorWidget: (_, __, ___) =>
                                      const Icon(Icons.image_not_supported, color: Colors.grey),
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
                                    child:
                                        const Icon(Icons.star, size: 12, color: Colors.white),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                      childCount: sightings.length,
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
                        'No identified sightings yet.\nIdentify photos in Activity to populate this profile.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade500, height: 1.6),
                      ),
                    ),
                  ),
                ),
              ],

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
// Cover Photo Card — full photo contained in a 16:9 card, no cropping
// ─────────────────────────────────────────────────────────────────────────────

class _CoverPhotoCard extends StatelessWidget {
  final Bird bird;
  final VoidCallback? onChangeCover;
  const _CoverPhotoCard({required this.bird, this.onChangeCover});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: AspectRatio(
        aspectRatio: 16 / 9,
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
                      child: Icon(Icons.pets, size: 72,
                          color: theme.primaryColor.withValues(alpha: 0.3)),
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
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
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
            width: 10,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          ),
        ],
      ),
    );

    return SizedBox(
      height: 180,
      child: BarChart(BarChartData(
        maxY: maxCount > 0 ? maxCount + 1 : 5,
        barGroups: bars,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: Colors.grey.shade200, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: maxCount > 4 ? (maxCount / 4).ceilToDouble() : 1,
              getTitlesWidget: (v, _) =>
                  Text(v.toInt().toString(), style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 3,
              getTitlesWidget: (v, _) {
                final h = v.toInt();
                if (h % 3 != 0) return const SizedBox.shrink();
                final lbl = h == 0 ? '12a' : h < 12 ? '${h}a' : h == 12 ? '12p' : '${h - 12}p';
                return Text(lbl, style: const TextStyle(fontSize: 9, color: Colors.grey));
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
              final lbl =
                  h == 0 ? '12am' : h < 12 ? '${h}am' : h == 12 ? '12pm' : '${h - 12}pm';
              return BarTooltipItem(
                '$lbl\n${rod.toY.toInt()} sighting${rod.toY.toInt() != 1 ? 's' : ''}',
                const TextStyle(color: Colors.white, fontSize: 12),
              );
            },
          ),
        ),
      )),
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
            width: 10,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          ),
        ],
      ),
    );
    const monthLabels = {0: 'Jan', 4: 'Mar', 8: 'May', 12: 'Jul', 17: 'Sep', 21: 'Nov'};

    return SizedBox(
      height: 180,
      child: BarChart(BarChartData(
        maxY: maxCount > 0 ? maxCount + 1 : 5,
        barGroups: bars,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: Colors.grey.shade200, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: maxCount > 4 ? (maxCount / 4).ceilToDouble() : 1,
              getTitlesWidget: (v, _) =>
                  Text(v.toInt().toString(), style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) {
                final lbl = monthLabels[v.toInt()];
                if (lbl == null) return const SizedBox.shrink();
                return Text(lbl, style: const TextStyle(fontSize: 9, color: Colors.grey));
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
              return BarTooltipItem(
                'Day $startDay–${startDay + 13}\n${rod.toY.toInt()} sighting${rod.toY.toInt() != 1 ? 's' : ''}',
                const TextStyle(color: Colors.white, fontSize: 12),
              );
            },
          ),
        ),
      )),
    );
  }
}
