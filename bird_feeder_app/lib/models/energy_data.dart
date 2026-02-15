// lib/models/energy_data.dart

import 'package:cloud_firestore/cloud_firestore.dart';

class EnergyData {
  final DateTime timestamp;
  final double batteryVoltage;
  final double chargeVoltage;
  final double batteryPercent;

  EnergyData({
    required this.timestamp,
    required this.batteryVoltage,
    required this.chargeVoltage,
    required this.batteryPercent,
  });

  /// Factory constructor to create an EnergyData object from a Firestore document.
  factory EnergyData.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;

    if (data == null) {
      throw Exception("Document data is null.");
    }
    
    // Read nested data
    final batteryData = data['battery'] as Map<String, dynamic>? ?? {};
    final solarData = data['solar'] as Map<String, dynamic>? ?? {};

    final dynamic timestampValue = data['timestamp'];
    DateTime parsedTimestamp;

    // 💡 FINAL LOGIC: Check type and parse accordingly. 
    // New data is a String, old data is Timestamp.
    if (timestampValue is Timestamp) {
      // Handles old data logged using SERVER_TIMESTAMP
      parsedTimestamp = timestampValue.toDate();
    } else if (timestampValue is String) {
      // Handles new data logged as an ISO-formatted string
      try {
        parsedTimestamp = DateTime.parse(timestampValue);
      } catch (e) {
        // Handle malformed strings if they exist
        print("Error parsing timestamp string: $timestampValue, using epoch. Error: $e");
        parsedTimestamp = DateTime.fromMillisecondsSinceEpoch(0);
      }
    } else {
      // Fallback for unexpected types
      print("Warning: Unknown timestamp type received: ${timestampValue.runtimeType}");
      parsedTimestamp = DateTime.fromMillisecondsSinceEpoch(0); 
    }

    return EnergyData(
      timestamp: parsedTimestamp,
      batteryVoltage: (batteryData['voltage'] as num?)?.toDouble() ?? 0.0,
      batteryPercent: (batteryData['percent'] as num?)?.toDouble() ?? 0.0,
      chargeVoltage: (solarData['voltage'] as num?)?.toDouble() ?? 0.0,
    );
  }
}