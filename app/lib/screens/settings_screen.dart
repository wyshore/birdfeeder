import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/camera_settings.dart';
import '../config/firebase_paths.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // 1. Get a reference to the Firestore document
  final DocumentReference _settingsRef =
      FirebaseFirestore.instance.doc(ConfigPaths.settings);

  // Local state to hold current values, which are updated when Firestore data arrives
  CameraSettings? _localSettings;
  bool _isLoading = false; 
  
  // Track if local changes have been made but not yet saved
  bool _hasUnsavedChanges = false;
  
  // Helper to update local settings state and flag unsaved changes
  void _updateLocalSettings(CameraSettings newSettings) {
    // Only update state if changes are different from current local settings
    // We check for changes in the specific field being updated to prevent unnecessary re-saves
    if (newSettings != _localSettings) {
      setState(() {
        _localSettings = newSettings;
        _hasUnsavedChanges = true;
      });
    }
  }

  /// Writes the current local settings back to Firestore.
  Future<void> _saveSettings() async {
    if (_localSettings == null || !_hasUnsavedChanges) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // Use toFirestore() method from the model, which only contains the writable fields
      await _settingsRef.set(_localSettings!.toFirestore(), SetOptions(merge: true));
      
      setState(() {
        _hasUnsavedChanges = false;
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved successfully!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      print('ERROR saving settings: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save settings: $e'), backgroundColor: Colors.red),
        );
      }
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 2. Use a StreamBuilder to listen for real-time updates from Firestore
    return StreamBuilder<DocumentSnapshot>(
      stream: _settingsRef.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error loading settings: ${snapshot.error}'));
        }

        // Show spinner only on first load
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        
        // 3. Process the incoming data
        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>;
          
          // Use the model's factory to safely parse data
          final fetchedSettings = CameraSettings.fromFirestore(data);
          
          // CRITICAL: Only update the local settings if they haven't been modified locally,
          // OR if the fetched data is different from the current local data.
          // This prevents local changes from being overwritten by the stream listener.
          if (!_hasUnsavedChanges || _localSettings == null) {
              _localSettings = fetchedSettings;
          }
          
        } else if (_localSettings == null) {
           // Document doesn't exist yet, initialize with defaults and save them
           WidgetsBinding.instance.addPostFrameCallback((_) {
               if (!snapshot.data!.exists) {
                  _settingsRef.set(
                      CameraSettings.defaultSettings.toFirestore(),
                      SetOptions(merge: true)
                  ).catchError((e) => print('Initial save error: $e'));
               }
           });
           // Use default settings until the stream provides the saved data
           _localSettings = CameraSettings.defaultSettings; 
        }

        // Use the local state for building the UI
        final settings = _localSettings!;
        
        // Helper to format resolution array into a string
        String formatResolution(List<int> res) => '${res[0]}x${res[1]}';

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- Title (Fixed at the top) ---
              const Padding(
                padding: EdgeInsets.only(bottom: 16.0),
                child: Text(
                  'Camera Configuration Status',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.indigo),
                ),
              ),

              // --- Scrollable Content Area (New) ---
              // Expanded takes up the remaining available space after the title and button.
              // SingleChildScrollView allows the content inside to scroll if it overflows.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // --- MOTION CAPTURE RESOLUTION (Configurable/Status) ---
                      _buildStatusCard(
                        context,
                        title: 'Motion Capture Resolution',
                        subtitle: 'The high-resolution used by the Pi for motion-triggered images.',
                        value: formatResolution(settings.motionCaptureResolution),
                        icon: Icons.fullscreen_outlined,
                      ),
                      
                      const SizedBox(height: 12),
                      
                      // --- Snapshot Resolution (Read Only Status) ---
                      _buildStatusCard(
                        context,
                        title: 'Snapshot Resolution',
                        subtitle: 'A default resolution often used for quick previews or initial setup.',
                        value: formatResolution(settings.snapshotResolution), 
                        icon: Icons.photo_size_select_small_outlined,
                      ),

                      const SizedBox(height: 12),

                      // --- Stream Resolution (Read Only Status) ---
                      _buildStatusCard(
                        context,
                        title: 'Live Stream Resolution',
                        subtitle: 'The resolution the Pi is currently streaming for the live feed.',
                        value: formatResolution(settings.streamResolution), 
                        icon: Icons.videocam_outlined,
                      ),
                      
                      const SizedBox(height: 12),

                      // --- Stream Framerate (Read Only Status) ---
                      _buildStatusCard(
                        context,
                        title: 'Live Stream Framerate (FPS)',
                        subtitle: 'The frames per second used for the live stream.',
                        value: '${settings.framerate} FPS',
                        icon: Icons.speed_outlined,
                      ),

                      const SizedBox(height: 24),
                      
                      // --- Motion Captures Enabled (Toggleable) ---
                      _buildToggleCard(
                        context,
                        title: 'Motion Captures Enabled',
                        subtitle: settings.motionCaptureEnabled
                            ? 'The Pi is actively monitoring for motion.'
                            : 'Monitoring is disabled. Only manual captures are possible.',
                        value: settings.motionCaptureEnabled,
                        onChanged: (bool value) {
                          // Only update the local settings for the toggle
                          _updateLocalSettings(settings.copyWith(motionCaptureEnabled: value));
                        },
                      ),
                      const SizedBox(height: 16), // Add padding at the bottom of the scrollable content
                    ],
                  ),
                ),
              ),
              
              // --- Save Button (Fixed at the bottom) ---
              // Removed the Spacer here
              ElevatedButton.icon(
                onPressed: _hasUnsavedChanges && !_isLoading ? _saveSettings : null,
                icon: _isLoading && _hasUnsavedChanges ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)
                ) : const Icon(Icons.save),
                label: Text(_hasUnsavedChanges ? 'SAVE CHANGES' : 'Settings Up to Date'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 5,
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  // Helper method to create a clean-looking status card
  Widget _buildStatusCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String value,
    required IconData icon,
  }) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(icon, size: 30, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                  ),
                ],
              ),
            ),
            // The value display
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.secondary, // Use secondary color for emphasis
                  ),
            ),
          ],
        ),
      ),
    );
  }

  // Helper method to create a card with a toggle switch
  Widget _buildToggleCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}