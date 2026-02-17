import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/camera_settings.dart';
import '../config/firebase_paths.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final DocumentReference _settingsRef =
      FirebaseFirestore.instance.doc(ConfigPaths.settings);

  StreamSubscription? _subscription;
  CameraSettings? _localSettings;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    _subscription = _settingsRef.snapshots().listen((snapshot) {
      if (!mounted) return;
      if (snapshot.exists) {
        final fetched = CameraSettings.fromFirestore(snapshot.data() as Map<String, dynamic>);
        if (!_hasUnsavedChanges || _localSettings == null) {
          setState(() {
            _localSettings = fetched;
            _isLoading = false;
          });
        }
      } else {
        // Document doesn't exist, create with defaults
        _settingsRef.set(CameraSettings.defaultSettings.toFirestore(), SetOptions(merge: true));
        setState(() {
          _localSettings = CameraSettings.defaultSettings;
          _isLoading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _update(CameraSettings newSettings) {
    setState(() {
      _localSettings = newSettings;
      _hasUnsavedChanges = true;
    });
  }

  Future<void> _saveSettings() async {
    if (_localSettings == null || !_hasUnsavedChanges) return;
    setState(() => _isSaving = true);
    try {
      await _settingsRef.set(_localSettings!.toFirestore(), SetOptions(merge: true));
      setState(() {
        _hasUnsavedChanges = false;
        _isSaving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), backgroundColor: Colors.red),
        );
      }
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _localSettings == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final s = _localSettings!;
    String fmtRes(List<int> r) => '${r[0]}x${r[1]}';

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 16.0),
            child: Text(
              'Camera Settings',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.indigo),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ======== GENERAL ========
                  _sectionHeader('General'),
                  _buildToggleCard(
                    title: 'Motion Capture',
                    subtitle: s.motionCaptureEnabled
                        ? 'Pi is monitoring for motion'
                        : 'Motion detection disabled',
                    value: s.motionCaptureEnabled,
                    onChanged: (v) => _update(s.copyWith(motionCaptureEnabled: v)),
                  ),
                  _buildStatusCard(title: 'Capture Resolution', value: fmtRes(s.motionCaptureResolution), icon: Icons.fullscreen),
                  _buildStatusCard(title: 'Stream Resolution (fixed)', value: fmtRes(s.streamResolution), icon: Icons.videocam_outlined),

                  // ======== FOCUS ========
                  _sectionHeader('Focus'),
                  _buildDropdownCard<String>(
                    title: 'Autofocus Mode',
                    value: s.afMode,
                    items: const {'continuous': 'Continuous AF', 'manual': 'Manual Focus'},
                    onChanged: (v) => _update(s.copyWith(afMode: v)),
                  ),
                  if (s.afMode == 'manual')
                    _buildNumberCard(
                      title: 'Lens Position (dioptres)',
                      subtitle: 'Higher = closer focus. 2.5 = 400mm, 5.0 = 200mm, 10.0 = 100mm',
                      value: s.lensPosition,
                      min: 0.0,
                      max: 10.0,
                      decimals: 1,
                      onChanged: (v) => _update(s.copyWith(lensPosition: v)),
                    ),

                  // ======== EXPOSURE ========
                  _sectionHeader('Exposure'),
                  _buildIntCard(
                    title: 'Exposure Time (us)',
                    subtitle: '0 = auto. Lower = less motion blur. Max 66666',
                    value: s.exposureTime,
                    min: 0,
                    max: 66666,
                    onChanged: (v) => _update(s.copyWith(exposureTime: v)),
                  ),
                  _buildNumberCard(
                    title: 'Analogue Gain',
                    subtitle: '0 = auto. 1.0-16.0 manual. Higher = brighter but noisier',
                    value: s.analogueGain,
                    min: 0.0,
                    max: 16.0,
                    decimals: 1,
                    onChanged: (v) => _update(s.copyWith(analogueGain: v)),
                  ),
                  if (s.exposureTime == 0) ...[
                    _buildDropdownCard<String>(
                      title: 'AE Mode',
                      value: s.aeExposureMode,
                      items: const {'normal': 'Normal', 'short': 'Short (faster shutter)'},
                      onChanged: (v) => _update(s.copyWith(aeExposureMode: v)),
                    ),
                    _buildNumberCard(
                      title: 'EV Compensation',
                      subtitle: 'Brighten (+) or darken (-) auto-exposure',
                      value: s.evCompensation,
                      min: -4.0,
                      max: 4.0,
                      decimals: 1,
                      onChanged: (v) => _update(s.copyWith(evCompensation: v)),
                    ),
                  ],

                  // ======== IMAGE PROCESSING ========
                  _sectionHeader('Image Processing'),
                  _buildNumberCard(
                    title: 'Sharpness',
                    value: s.sharpness, min: 0.0, max: 8.0, decimals: 1,
                    onChanged: (v) => _update(s.copyWith(sharpness: v)),
                  ),
                  _buildNumberCard(
                    title: 'Contrast',
                    value: s.contrast, min: 0.0, max: 4.0, decimals: 1,
                    onChanged: (v) => _update(s.copyWith(contrast: v)),
                  ),
                  _buildNumberCard(
                    title: 'Saturation',
                    value: s.saturation, min: 0.0, max: 4.0, decimals: 1,
                    onChanged: (v) => _update(s.copyWith(saturation: v)),
                  ),
                  _buildNumberCard(
                    title: 'Brightness',
                    value: s.brightness, min: -1.0, max: 1.0, decimals: 1,
                    onChanged: (v) => _update(s.copyWith(brightness: v)),
                  ),

                  // ======== WHITE BALANCE & NOISE ========
                  _sectionHeader('White Balance & Noise'),
                  _buildDropdownCard<String>(
                    title: 'White Balance',
                    value: s.awbMode,
                    items: const {
                      'auto': 'Auto', 'daylight': 'Daylight', 'cloudy': 'Cloudy',
                      'indoor': 'Indoor', 'fluorescent': 'Fluorescent',
                      'tungsten': 'Tungsten', 'incandescent': 'Incandescent',
                    },
                    onChanged: (v) => _update(s.copyWith(awbMode: v)),
                  ),
                  _buildDropdownCard<String>(
                    title: 'Noise Reduction',
                    value: s.noiseReduction,
                    items: const {'high_quality': 'High Quality', 'fast': 'Fast', 'off': 'Off'},
                    onChanged: (v) => _update(s.copyWith(noiseReduction: v)),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // Save button
          ElevatedButton.icon(
            onPressed: _hasUnsavedChanges && !_isSaving ? _saveSettings : null,
            icon: _isSaving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                : const Icon(Icons.save),
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
  }

  // --- Builder Helpers ---

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8, left: 4),
      child: Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey[600], letterSpacing: 0.5)),
    );
  }

  Widget _buildStatusCard({required String title, required String value, required IconData icon}) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
            Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleCard({required String title, required String subtitle, required bool value, required ValueChanged<bool> onChanged}) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        child: Row(
          children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600])),
              ]),
            ),
            Switch.adaptive(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownCard<T>({required String title, required T value, required Map<T, String> items, required ValueChanged<T> onChanged}) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        child: Row(
          children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold))),
            DropdownButton<T>(
              value: items.containsKey(value) ? value : items.keys.first,
              underline: const SizedBox(),
              items: items.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) { if (v != null) onChanged(v); },
            ),
          ],
        ),
      ),
    );
  }

  /// Number input card for double values with min/max validation.
  Widget _buildNumberCard({
    required String title,
    required double value,
    required double min,
    required double max,
    required int decimals,
    required ValueChanged<double> onChanged,
    String? subtitle,
  }) {
    return _InputCard(
      title: title,
      subtitle: subtitle ?? '${min.toStringAsFixed(decimals)} - ${max.toStringAsFixed(decimals)}',
      initialValue: value.toStringAsFixed(decimals),
      allowDecimal: true,
      allowNegative: min < 0,
      onSubmitted: (text) {
        final parsed = double.tryParse(text);
        if (parsed != null) {
          onChanged(parsed.clamp(min, max));
        }
      },
    );
  }

  /// Number input card for integer values with min/max validation.
  Widget _buildIntCard({
    required String title,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
    String? subtitle,
  }) {
    return _InputCard(
      title: title,
      subtitle: subtitle ?? '$min - $max',
      initialValue: value.toString(),
      allowDecimal: false,
      allowNegative: min < 0,
      onSubmitted: (text) {
        final parsed = int.tryParse(text);
        if (parsed != null) {
          onChanged(parsed.clamp(min, max));
        }
      },
    );
  }
}

/// Stateful text input card that manages its own TextEditingController.
class _InputCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final String initialValue;
  final bool allowDecimal;
  final bool allowNegative;
  final ValueChanged<String> onSubmitted;

  const _InputCard({
    required this.title,
    required this.subtitle,
    required this.initialValue,
    required this.allowDecimal,
    required this.allowNegative,
    required this.onSubmitted,
  });

  @override
  State<_InputCard> createState() => _InputCardState();
}

class _InputCardState extends State<_InputCard> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(_InputCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only update text if the value changed externally (e.g. Firestore sync)
    // and the field is not currently focused
    if (oldWidget.initialValue != widget.initialValue) {
      final focusScope = FocusScope.of(context);
      final hasFocus = _controller.selection.isValid && focusScope.hasFocus;
      if (!hasFocus) {
        _controller.text = widget.initialValue;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Build input formatters
    final formatters = <TextInputFormatter>[
      FilteringTextInputFormatter.allow(
        RegExp(widget.allowNegative
            ? (widget.allowDecimal ? r'[0-9.\-]' : r'[0-9\-]')
            : (widget.allowDecimal ? r'[0-9.]' : r'[0-9]')),
      ),
    ];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        child: Row(
          children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(widget.subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600])),
              ]),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 100,
              child: TextField(
                controller: _controller,
                keyboardType: TextInputType.numberWithOptions(decimal: widget.allowDecimal, signed: widget.allowNegative),
                inputFormatters: formatters,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onSubmitted: (text) => widget.onSubmitted(text),
                onEditingComplete: () {
                  widget.onSubmitted(_controller.text);
                  FocusScope.of(context).unfocus();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
