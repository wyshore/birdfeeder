// lib/utils/mock_data_generator.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';

// Helper for linear interpolation
double mapRange(double value, double fromMin, double fromMax, double toMin, double toMax) {
  // Linearly map a value from one range to another
  return (value - fromMin) * (toMax - toMin) / (fromMax - fromMin) + toMin;
}

/// Generates and uploads realistic mock energy data to Firestore.
Future<void> uploadMockEnergyData() async {
  final firestore = FirebaseFirestore.instance;
  // Collection path: logs/energy/data
  final collection = firestore.collection('logs').doc('energy').collection('data'); 
  final Random random = Random();

  // 1. Define time parameters
  final int totalPoints = (7 * 24 * 60) ~/ 10; // 1008 points total
  const int intervalMinutes = 10;
  final DateTime now = DateTime.now();
  final DateTime startTime = now.subtract(const Duration(days: 7));
  
  print('Starting mock data upload: $totalPoints points over 7 days (every $intervalMinutes minutes)...');
  
  // Base voltage parameters
  const double minBatteryV = 3.2;
  const double maxBatteryV = 4.2;
  
  // 2. Loop through all data points
  for (int i = 0; i <= totalPoints; i++) {
    final DateTime timestamp = startTime.add(Duration(minutes: i * intervalMinutes));
    final double timeInHours = timestamp.difference(startTime).inMinutes / 60.0;
    
    // --- 2.1 Battery Voltage (3.2V to 4.2V) ---
    // Sine wave pattern to simulate charge/discharge cycles
    final double sinePattern = sin(timeInHours / (24 / (2 * pi))) * 0.4; 
    double batteryVoltage = 3.8 + sinePattern + (random.nextDouble() * 0.02 - 0.01);
    batteryVoltage = batteryVoltage.clamp(minBatteryV, maxBatteryV);

    // --- 2.2 Battery Percent (0 to 100) ---
    double batteryPercent = mapRange(batteryVoltage, minBatteryV, maxBatteryV, 0, 100);
    batteryPercent = batteryPercent.clamp(0.0, 100.0);

    // --- 2.3 Solar Charge Voltage (0V to 5V) ---
    final int hourOfDay = timestamp.hour;
    double chargeVoltage = 0.0;
    
    if (hourOfDay >= 7 && hourOfDay <= 17) { // Charging period (7am to 5pm)
        // Cosine wave to simulate solar intensity peaking at midday
        final double phase = (hourOfDay - 7) / 10 * pi;
        final double solarIntensity = cos(phase) * -1 + 1; // Range 0 to 2
        
        chargeVoltage = solarIntensity * 2.5 + (random.nextDouble() * 0.5); 
        chargeVoltage = chargeVoltage.clamp(0.0, 5.0);
    }
    
    // --- 3. Upload Data with NESTED STRUCTURE (Matching your image) ---
    final dataMap = {
      'timestamp': Timestamp.fromDate(timestamp),
      'battery': { 
          'voltage': double.parse(batteryVoltage.toStringAsFixed(3)),
          'percent': double.parse(batteryPercent.toStringAsFixed(1)),
      },
      'solar': { 
          'voltage': double.parse(chargeVoltage.toStringAsFixed(3)),
      },
      'system_health': {
          'cpu_temp_c': 39.2 + random.nextDouble() * 5,
          'disk_space_gb': 1.2,
      }
    };

    await collection.add(dataMap);
  }

  print('\n✅ Mock data upload complete! Total $totalPoints points uploaded.');
}

/// Utility function to delete all data from the energy log collection.
Future<void> deleteMockEnergyData() async {
  final collection = FirebaseFirestore.instance.collection('logs').doc('energy').collection('data');
  final batch = FirebaseFirestore.instance.batch();
  
  print('Starting deletion of all energy log documents...');

  // Use a query to fetch all documents
  final snapshot = await collection.get();

  if (snapshot.docs.isEmpty) {
    print('No documents found to delete.');
    return;
  }

  // Add all fetched documents to the batch for deletion
  for (var doc in snapshot.docs) {
    batch.delete(doc.reference);
  }

  // Commit the batch write
  await batch.commit();
  print('✅ Successfully deleted ${snapshot.docs.length} energy log documents.');
}