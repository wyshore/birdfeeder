import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/sighting.dart';
import '../config/firebase_paths.dart';
import 'catalog_screen.dart'; 

// --- Helper Extensions for Name Standardization (Kept) ---

/// Converts a string to Title Case (e.g., "american robin" -> "American Robin").
extension StringCasingExtension on String {
  String toTitleCase() {
    if (trim().isEmpty) return '';
    return trim().split(' ').map((word) {
      if (word.isEmpty) return '';
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }

  /// Converts a string to a slug (e.g., "American Robin" -> "american-robin").
  String toSlug() {
    return trim().toLowerCase().replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(RegExp(r'\s+'), '-');
  }
}

/// Defines the structure for the tab view
class _GalleryTab {
  const _GalleryTab(this.name, this.collectionId);
  final String name;
  final String collectionId; // e.g., 'motion_captures' or 'snapshots'
}

/// --- Main Gallery Screen ---
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});
  
  // Moved to public class to be accessible by _SightingDetailsSheetState
  static const String catalogCollectionRoot = 'catalog/birds';

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> with SingleTickerProviderStateMixin {
  
  // Selection State (Internalized)
  // Key: Collection ID, Value: Set of selected Sighting IDs
  final Map<String, Set<String>> _selectedSightings = {
    'motion_captures': {},
    'snapshots': {},
  };
  
  bool _isSelectionMode = false;
  
  // Tab Controller Initialization
  late final TabController _tabController; 
  
  final tabs = const [
    _GalleryTab('Motion Captures', 'motion_captures'),
    _GalleryTab('Snapshots', 'snapshots'),
  ];

  @override
  void initState() {
    super.initState();
    
    _tabController = TabController(length: tabs.length, vsync: this);
    
    // Clear selection state when switching tabs to prevent confusion
    _tabController.addListener(_onTabChange);
  }
  
  @override
  void dispose() {
    _tabController.removeListener(_onTabChange);
    _tabController.dispose();
    super.dispose();
  }

  // --- Internal Selection Logic ---

  String get _currentCollectionId => tabs[_tabController.index].collectionId;
  
  void _onTabChange() {
    // Exit selection mode when switching tabs and clear selection
    if (_isSelectionMode) {
      // Use a post-frame callback to ensure the state update happens after the tab change
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _toggleSelectionMode(false);
        }
      });
    }
  }

  Set<String> _getSelectedIds(String collectionId) {
    return _selectedSightings[collectionId] ?? {};
  }
  
  int _getSelectionCount(String collectionId) {
    return _getSelectedIds(collectionId).length;
  }
  
  bool _isSelected(String collectionId, String sightingId) {
    return _getSelectedIds(collectionId).contains(sightingId);
  }

  /// Toggles the main selection mode.
  void _toggleSelectionMode(bool value) {
    if (_isSelectionMode == value) return;
    
    setState(() {
      _isSelectionMode = value;
      if (!_isSelectionMode) {
        // Clear all selection when exiting mode
        _selectedSightings.forEach((key, value) => value.clear());
      }
    });
  }

  /// Toggles the selection status of a single sighting.
  void _toggleSelection(String collectionId, String sightingId) {
    setState(() {
      final selectedSet = _selectedSightings[collectionId]!;
      
      if (_isSelected(collectionId, sightingId)) {
        selectedSet.remove(sightingId);
      } else {
        selectedSet.add(sightingId);
      }

      // After updating, check if we need to exit selection mode
      if (_isSelectionMode && selectedSet.isEmpty) {
        _isSelectionMode = false;
      } 
    });
  }
  
  // --- Firebase Access Helpers ---

  String _getSightingCollectionPath(String collectionId) {
    return LogPaths.getLogPath(collectionId);
  }

  // Uses the public static constant
  String _getCatalogCollectionPath() {
    return GalleryScreen.catalogCollectionRoot;
  }
  
  // Deletes all selected sightings and their images from Firebase.
  Future<void> _deleteSelectedSightings() async {
    final collectionId = _currentCollectionId;
    final idsToDelete = Set<String>.from(_selectedSightings[collectionId]!);
    
    if (idsToDelete.isEmpty) return;

    final collectionPath = _getSightingCollectionPath(collectionId);
    final firestore = FirebaseFirestore.instance;
    final storage = FirebaseStorage.instance;
    final batch = firestore.batch();

    // Immediately clear selection state in UI (before operation)
    setState(() {
      _selectedSightings[collectionId]!.clear();
      _isSelectionMode = false;
    });

    try {
      for (final id in idsToDelete) {
        final docRef = firestore.collection(collectionPath).doc(id);
        
        // Fetch document data to get the storagePath before deleting
        final docSnapshot = await docRef.get();
        final sightingData = docSnapshot.data();
        final storagePath = sightingData?['storagePath'] as String?;

        batch.delete(docRef);

        if (storagePath != null && storagePath.isNotEmpty) {
          try {
            await storage.ref(storagePath).delete();
          } catch (e) {
            print('Warning: Failed to delete image for $id at $storagePath: $e');
          }
        }
      }

      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted ${idsToDelete.length} sighting(s).')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete sighting(s): $e')),
        );
      }
    }
  }

  // Shows the details sheet for a single sighting
  void _showSightingDetails(Sighting sighting, String collectionId) {
    if (_isSelectionMode) return;
    // Use showGeneralDialog for a true full-screen experience
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.9), // Dark overlay
      barrierDismissible: true,
      barrierLabel: 'Close',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return _SightingDetailsScreen(
          sighting: sighting,
          sightingCollectionPath: _getSightingCollectionPath(collectionId),
          catalogCollectionPath: _getCatalogCollectionPath(),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: const Offset(0, 0)).animate(anim1),
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    
    final currentCollectionId = _currentCollectionId;
    final currentSelectionCount = _getSelectionCount(currentCollectionId);

    // Determine the action button logic based on mode
    final Widget actionButton;
    if (_isSelectionMode) {
      actionButton = TextButton(
        onPressed: () => _toggleSelectionMode(false),
        child: const Text('Done', style: TextStyle(color: Colors.white)),
      );
    } else {
      actionButton = IconButton(
        icon: const Icon(Icons.select_all, color: Colors.white),
        onPressed: () => _toggleSelectionMode(true),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isSelectionMode ? 'Select Items ($currentSelectionCount)' : 'Sighting Gallery', 
          style: const TextStyle(fontWeight: FontWeight.bold)
        ),
        backgroundColor: Theme.of(context).primaryColor,
        actions: [actionButton],
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: tabs.map((tab) => Tab(text: tab.name)).toList(),
        ),
      ),
      body: TabBarView(
          controller: _tabController,
          children: tabs.map((tab) => 
            // Use ValueKey to ensure Flutter preserves the State of the tab 
            // when the parent rebuilds due to selection changes.
            _SightingGridTab(
              key: ValueKey(tab.collectionId), 
              collectionId: tab.collectionId,
              isSelectionMode: _isSelectionMode,
              // Pass down callbacks and selection state checkers
              isSelected: (sightingId) => _isSelected(tab.collectionId, sightingId), 
              onTap: (sighting) {
                if (_isSelectionMode) {
                  _toggleSelection(tab.collectionId, sighting.id);
                } else {
                  _showSightingDetails(sighting, tab.collectionId);
                }
              },
              onLongPress: (sighting) {
                if (!_isSelectionMode) {
                  _toggleSelectionMode(true);
                }
                _toggleSelection(tab.collectionId, sighting.id);
              },
              getCollectionPath: _getSightingCollectionPath, 
            )
          ).toList(),
      ),
      // FAB only appears when selection mode is active and items are selected
      floatingActionButton: _isSelectionMode && currentSelectionCount > 0
          ? FloatingActionButton.extended(
              onPressed: _deleteSelectedSightings,
              label: Text('Delete ($currentSelectionCount)'),
              icon: const Icon(Icons.delete),
              backgroundColor: Colors.red,
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

// ====================================================================
// --- Stable Widget for Grid Content (StatefulWidget) ---
// ====================================================================

/// Refactored to StatefulWidget to guarantee the stream connection is 
/// initialized once in initState and remains stable across parent rebuilds.
class _SightingGridTab extends StatefulWidget {
  final String collectionId;
  final bool isSelectionMode;
  final bool Function(String sightingId) isSelected;
  final void Function(Sighting) onTap;
  final void Function(Sighting) onLongPress;
  final String Function(String collectionId) getCollectionPath;

  const _SightingGridTab({
    super.key,
    required this.collectionId,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.getCollectionPath,
  });

  @override
  State<_SightingGridTab> createState() => _SightingGridTabState();
}

class _SightingGridTabState extends State<_SightingGridTab> {
  
  // The stable Stream object is now stored in State
  late final Stream<List<Sighting>> _sightingsStream;

  @override
  void initState() {
    super.initState();
    // Initialize stream ONLY ONCE, preventing re-connection on parent setState
    _sightingsStream = _loadSightings();
  }
  
  // Fetches sightings for a specific collection 
  Stream<List<Sighting>> _loadSightings() {
    final collectionPath = widget.getCollectionPath(widget.collectionId);
    return FirebaseFirestore.instance
        .collection(collectionPath)
        .orderBy('timestamp', descending: true)
        .limit(50) 
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => Sighting.fromFirestore(doc)) 
              .toList();
        });
  }
  
  @override
  Widget build(BuildContext context) {
    // StreamBuilder now uses the stable stream object, preventing re-subscription
    return StreamBuilder<List<Sighting>>(
      stream: _sightingsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Padding(
             padding: const EdgeInsets.all(32.0),
             child: Text(
               'Error fetching sightings: ${snapshot.error}', 
               textAlign: TextAlign.center,
               style: const TextStyle(color: Colors.red, fontSize: 16),
             ),
           ));
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          // No need to show loading after initial load, as we want to reuse old data
          // but since we rely on `snapshot.data`, we keep this for first load.
          return const Center(child: CircularProgressIndicator());
        }

        final sightings = snapshot.data ?? [];

        if (sightings.isEmpty) {
          return const Center(
              child: Text('No sightings recorded yet.', style: TextStyle(fontSize: 18))
          );
        }
        
        return GridView.builder(
          padding: const EdgeInsets.all(8.0),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            // Five columns as requested
            crossAxisCount: 5, 
            crossAxisSpacing: 8.0,
            mainAxisSpacing: 8.0,
            childAspectRatio: 1.0,
          ),
          itemCount: sightings.length,
          itemBuilder: (context, index) {
            final sighting = sightings[index];
            
            return _SightingTile(
              sighting: sighting,
              collectionId: widget.collectionId,
              // These properties will change, triggering a targeted rebuild of the tile
              isSelected: widget.isSelected(sighting.id), 
              isSelectionMode: widget.isSelectionMode,
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
            );
          },
        );
      },
    );
  }
}

// ====================================================================
// --- Isolated Tile Widget (Unchanged) ---
// ====================================================================

class _SightingTile extends StatelessWidget {
  final Sighting sighting;
  final String collectionId;
  final bool isSelected;
  final bool isSelectionMode;
  final void Function(Sighting) onTap;
  final void Function(Sighting) onLongPress;

  const _SightingTile({
    required this.sighting,
    required this.collectionId,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    required this.onLongPress,
    super.key, 
  });

  @override
  Widget build(BuildContext context) {
    // ValueKey is crucial for performance here, ensuring Flutter correctly
    // identifies which tiles need updates when isSelected changes, and 
    // prevents unnecessary rebuilds/reloads of the CachedNetworkImage.
    return GridTile(
      key: ValueKey(sighting.id), 
      child: InkWell(
        onTap: () => onTap(sighting),
        onLongPress: () => onLongPress(sighting),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Stable Content (Image and Identification Overlay)
            ClipRRect(
              borderRadius: BorderRadius.circular(10.0),
              child: CachedNetworkImage(
                imageUrl: sighting.imageUrl,
                fit: BoxFit.cover,
                placeholder: (context, url) => Center(
                  child: CircularProgressIndicator(
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                errorWidget: (context, url, error) =>
                    const Center(child: Icon(Icons.image_not_supported, size: 50, color: Colors.grey)),
              ),
            ),
            
            // Identification Overlay (Always visible)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 6.0),
                decoration: BoxDecoration(
                  color: sighting.isIdentified ? Theme.of(context).primaryColor.withOpacity(0.8) : Colors.black54,
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10.0)),
                ),
                child: Row(
                  children: [
                    Icon(
                      sighting.isIdentified ? Icons.verified : Icons.help_outline,
                      color: Colors.white,
                      size: 12, // Smaller icon for 5-column layout
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        sighting.displaySpecies,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 10, // Smaller font for 5-column layout
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            // 2. Selection Overlay - Controlled by passed properties
            if (isSelectionMode) 
              Stack(
                fit: StackFit.expand,
                children: [
                  // Full Selection Overlay (visual feedback)
                  if (isSelected) 
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(10.0),
                        border: Border.all(color: Theme.of(context).primaryColor, width: 3),
                      ),
                    ),
                    
                  // Selection Checkmark/Icon
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.all(1), // Reduced padding
                      decoration: BoxDecoration(
                        color: isSelected ? Theme.of(context).primaryColor : Colors.black54,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: Icon(
                        isSelected ? Icons.check : Icons.circle_outlined,
                        color: Colors.white,
                        size: 16, // Reduced size
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ====================================================================
// --- Full-Screen Sighting Details/Identification Screen (New) ---
// ====================================================================

/// Replaces the small BottomSheet with a full-screen viewer.
class _SightingDetailsScreen extends StatefulWidget {
  final Sighting sighting;
  final String sightingCollectionPath; 
  final String catalogCollectionPath;

  const _SightingDetailsScreen({
    required this.sighting, 
    required this.sightingCollectionPath,
    required this.catalogCollectionPath,
  });

  @override
  State<_SightingDetailsScreen> createState() => _SightingDetailsScreenState();
}

class _SightingDetailsScreenState extends State<_SightingDetailsScreen> {
  late TextEditingController _speciesController;
  bool _isLoading = false;
  
  // Controller for InteractiveViewer to reset zoom
  final TransformationController _transformationController = TransformationController();
  // Using const to ensure stability
  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;

  @override
  void initState() {
    super.initState();
    _speciesController = TextEditingController(
      text: widget.sighting.speciesName.isNotEmpty
          ? widget.sighting.speciesName
          : '',
    );
  }

  @override
  void dispose() {
    _speciesController.dispose();
    _transformationController.dispose();
    super.dispose();
  }
  
  // --- Resolution Parsing ---
  
  /// Parses "1920x1080" into the aspect ratio (1920 / 1080).
  double _parseAspectRatio(String resolution) {
    final parts = resolution.split('x');
    if (parts.length == 2) {
      final width = double.tryParse(parts[0]);
      final height = double.tryParse(parts[1]);
      if (width != null && height != null && width > 0 && height > 0) {
        return width / height;
      }
    }
    // Default to a 16:9 ratio if parsing fails
    return 16 / 9; 
  }

  // --- Deletion Logic ---

  Future<void> _deleteSighting() async {
    // 1. Show confirmation dialog
    final bool? confirmDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Deletion'),
        content: Text('Are you sure you want to delete this sighting? This will remove the image from storage and the log entry.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmDelete != true) return;

    setState(() { _isLoading = true; });

    try {
      final firestore = FirebaseFirestore.instance;
      final storage = FirebaseStorage.instance;
      final sightingDocRef = firestore
          .collection(widget.sightingCollectionPath)
          .doc(widget.sighting.id);

      // Delete document
      await sightingDocRef.delete();

      // Delete image from storage
      final storagePath = widget.sighting.storagePath;
      if (storagePath.isNotEmpty) {
        await storage.ref(storagePath).delete();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sighting deleted successfully.')),
        );
        // Close the details screen after deletion
        Navigator.of(context).pop(); 
      }
    } catch (e) {
      print('Failed to delete sighting: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete sighting. Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() { _isLoading = false; });
      }
    }
  }
  
  // --- Identification Logic (Identical to previous) ---

  Future<void> _confirmSighting() async {
    if (_speciesController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a bird name.')),
      );
      return;
    }

    setState(() { _isLoading = true; });

    try {
      final commonName = _speciesController.text.toTitleCase();
      final catalogBirdId = commonName.toSlug();

      final firestore = FirebaseFirestore.instance;
      
      // Access the public static constant on GalleryScreen
      final catalogDocRef = firestore
          .collection(GalleryScreen.catalogCollectionRoot) 
          .doc(catalogBirdId);
      final sightingDocRef = firestore
          .collection(widget.sightingCollectionPath)
          .doc(widget.sighting.id);

      await firestore.runTransaction((transaction) async {
        final catalogSnapshot = await transaction.get(catalogDocRef);

        if (catalogSnapshot.exists) {
          transaction.update(catalogDocRef, {
            'sightingCount': FieldValue.increment(1),
            'lastSeen': FieldValue.serverTimestamp(),
          });
        } else {
          // This relies on the Bird model and its static helper from the other file (catalog_screen.dart)
          final newCatalogData = Bird.createNewCatalogEntry(
            speciesName: commonName,
            imageStoragePath: widget.sighting.imageUrl,
          );
          transaction.set(catalogDocRef, newCatalogData);
        }

        transaction.update(sightingDocRef, {
          'isIdentified': true,
          'catalogBirdId': catalogBirdId,
          'speciesName': commonName, 
        });
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sighting successfully identified as $commonName.')),
        );
        Navigator.of(context).pop();
      }

    } catch (e) {
      print('Firestore transaction failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to confirm sighting. Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() { _isLoading = false; });
      }
    }
  }
  
  // Helper to build consistent metadata rows
  Widget _buildMetadataRow(String title, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80, // Fixed width for titles
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String sheetTitle = widget.sighting.isIdentified
        ? 'Update Identification'
        : 'Identify This Bird';
        
    final double aspectRatio = _parseAspectRatio(widget.sighting.resolution);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // --- Header & Close Button ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    sheetTitle,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Row(
                    children: [
                      // Button to reset zoom/pan
                      IconButton(
                        icon: const Icon(Icons.zoom_out_map, color: Colors.white),
                        onPressed: () => _transformationController.value = Matrix4.identity(),
                        tooltip: 'Reset Zoom & Pan',
                      ),
                      // Close button
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            
            const Divider(color: Colors.white30, height: 1),

            // --- Main Content: Image Viewer (Top) and Controls (Bottom) ---
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. Zoomable Image Viewer (Approx 65% width)
                    Expanded(
                      flex: 2,
                      // *** NEW: AspectRatio applied to the viewer container ***
                      child: AspectRatio(
                        aspectRatio: aspectRatio,
                        child: Container(
                          padding: const EdgeInsets.all(2.0),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade900,
                            borderRadius: BorderRadius.circular(12.0),
                            // Neat Border using primary color
                            border: Border.all(color: theme.primaryColor.withOpacity(0.7), width: 3.0),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10.0),
                            child: Container(
                              color: Colors.black, // Background for the image area
                              // Simplified InteractiveViewer using strict bounds
                              child: InteractiveViewer(
                                transformationController: _transformationController,
                                boundaryMargin: EdgeInsets.zero, 
                                minScale: _minScale,
                                maxScale: _maxScale,
                                
                                child: CachedNetworkImage(
                                  imageUrl: widget.sighting.imageUrl,
                                  fit: BoxFit.contain, // Correctly shows the whole image
                                  placeholder: (context, url) => Center(
                                    child: CircularProgressIndicator(color: theme.primaryColor),
                                  ),
                                  errorWidget: (context, url, error) =>
                                      const Center(child: Icon(Icons.image_not_supported, size: 100, color: Colors.grey)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    
                    const SizedBox(width: 16),

                    // 2. Identification and Metadata Panel (Approx 35% width)
                    Expanded(
                      flex: 1,
                      child: Container(
                        padding: const EdgeInsets.all(16.0),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade900, // Dark background for contrast
                          borderRadius: BorderRadius.circular(12.0),
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Sighting Status
                              Text(
                                widget.sighting.isIdentified
                                    ? 'Current: ${widget.sighting.speciesName}'
                                    : 'Status: Unidentified Sighting',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: widget.sighting.isIdentified ? theme.primaryColor : Colors.orange,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              
                              const SizedBox(height: 16),
                              
                              // Metadata
                              _buildMetadataRow('Captured:', widget.sighting.timestamp.toString().substring(0, 16), Colors.white70),
                              _buildMetadataRow('Resolution:', widget.sighting.resolution, Colors.white70),
                              _buildMetadataRow('Source:', widget.sightingCollectionPath.contains('motion_captures') ? 'Motion Capture' : 'Snapshot', Colors.white70),
                              
                              const Divider(color: Colors.white30, height: 32),
                              
                              // Identification Form
                              Text(
                                'Identify Bird Species',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  color: theme.primaryColor,
                                ),
                              ),
                              const SizedBox(height: 12),
                              
                              TextFormField(
                                controller: _speciesController,
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  hintText: 'e.g., American Robin',
                                  hintStyle: TextStyle(color: Colors.grey.shade600),
                                  border: const OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(10)),
                                    borderSide: BorderSide(color: Colors.white54)
                                  ),
                                  enabledBorder: const OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(10)),
                                    borderSide: BorderSide(color: Colors.white54)
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: const BorderRadius.all(Radius.circular(10)),
                                    borderSide: BorderSide(color: theme.primaryColor, width: 2)
                                  ),
                                  filled: true,
                                  fillColor: Colors.grey.shade800,
                                  suffixIcon: _speciesController.text.isNotEmpty
                                      ? IconButton(
                                    icon: const Icon(Icons.clear, color: Colors.white70),
                                    onPressed: () => _speciesController.clear(),
                                  )
                                      : null,
                                ),
                                onFieldSubmitted: (_) => _confirmSighting(),
                              ),
                              const SizedBox(height: 16),
                              
                              ElevatedButton.icon(
                                onPressed: _isLoading ? null : _confirmSighting,
                                icon: _isLoading
                                    ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                                    : const Icon(Icons.check_circle_outline),
                                label: Text(
                                  _isLoading
                                      ? 'Confirming...'
                                      : (widget.sighting.isIdentified ? 'Update Identification' : 'Confirm Identification'),
                                  style: const TextStyle(fontSize: 16),
                                ),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  backgroundColor: theme.primaryColor,
                                  foregroundColor: Colors.white,
                                  elevation: 4,
                                ),
                              ),
                              
                              const SizedBox(height: 32),
                              
                              // *** NEW: Delete Button ***
                              OutlinedButton.icon(
                                onPressed: _isLoading ? null : _deleteSighting,
                                icon: const Icon(Icons.delete_forever),
                                label: const Text(
                                  'No Birds? Delete me!',
                                  style: TextStyle(fontSize: 14),
                                ),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  foregroundColor: Colors.red.shade400,
                                  side: BorderSide(color: Colors.red.shade400, width: 1),
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
}