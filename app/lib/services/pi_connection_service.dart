/// Service for managing Pi connection state.
///
/// This service listens to the Pi's heartbeat document in Firestore
/// and provides the Pi's IP address and online status to the UI.
///
/// Replaces the old globals.dart mutable global with proper state management.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../config/firebase_paths.dart';

class PiConnectionService extends ChangeNotifier {
  // Singleton pattern
  static final PiConnectionService _instance = PiConnectionService._internal();
  factory PiConnectionService() => _instance;
  PiConnectionService._internal();

  // Pi connection state
  String? _ipAddress;
  bool _isOnline = false;
  DateTime? _lastSeen;

  // Firestore listener
  StreamSubscription<DocumentSnapshot>? _heartbeatSubscription;

  /// Get current Pi IP address
  String get ipAddress => _ipAddress ?? '10.0.0.47'; // Fallback IP

  /// Check if Pi is online (seen in last 60 seconds)
  bool get isOnline => _isOnline;

  /// Get last seen timestamp
  DateTime? get lastSeen => _lastSeen;

  /// Start listening to Pi heartbeat
  void startListening() {
    // Cancel existing subscription if any
    _heartbeatSubscription?.cancel();

    final firestore = FirebaseFirestore.instance;

    _heartbeatSubscription = firestore
        .doc(StatusPaths.heartbeat)
        .snapshots()
        .listen(
      (snapshot) {
        if (!snapshot.exists) {
          _updateStatus(null, false, null);
          return;
        }

        final data = snapshot.data();
        if (data == null) {
          _updateStatus(null, false, null);
          return;
        }

        // Extract data
        final ip = data['ip_address'] as String?;
        final timestamp = data['last_seen'] as Timestamp?;
        final status = data['status'] as String?;

        // Determine if online (seen in last 60 seconds)
        bool online = false;
        DateTime? lastSeenTime;

        if (timestamp != null) {
          lastSeenTime = timestamp.toDate();
          final secondsSinceLastSeen =
              DateTime.now().difference(lastSeenTime).inSeconds;
          online = secondsSinceLastSeen < 60 && status == 'online';
        }

        _updateStatus(ip, online, lastSeenTime);
      },
      onError: (error) {
        debugPrint('Error listening to Pi heartbeat: $error');
        _updateStatus(null, false, null);
      },
    );
  }

  /// Stop listening to Pi heartbeat
  void stopListening() {
    _heartbeatSubscription?.cancel();
    _heartbeatSubscription = null;
  }

  /// Update connection status and notify listeners
  void _updateStatus(String? ip, bool online, DateTime? lastSeen) {
    bool changed = false;

    if (_ipAddress != ip) {
      _ipAddress = ip;
      changed = true;
    }

    if (_isOnline != online) {
      _isOnline = online;
      changed = true;
    }

    if (_lastSeen != lastSeen) {
      _lastSeen = lastSeen;
      changed = true;
    }

    if (changed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }
}
