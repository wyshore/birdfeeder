// lib/main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'config/firebase_paths.dart';
import 'services/pi_connection_service.dart';
import 'screens/home_screen.dart';


void main() async {
  // 1. Ensure widgets are initialized before running Firebase commands
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // 2. Initialize Firebase using the generated configuration options
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    print("Firebase Initialized Successfully.");

    // 🛑 REMINDER: TEMPORARILY CALL THE UPLOAD FUNCTION HERE
    // await uploadMockEnergyData(); 
    // await deleteMockEnergyData();
    // 🛑 IMPORTANT: After running once to get data, make sure both lines above are COMMENTED OUT or DELETED.

  } catch (e) {
    // CRITICAL: Log any initialization errors
    print("FATAL ERROR: Failed to initialize Firebase: $e");
    // Optionally, you might display an error screen here instead of running the app.
  }
  
  // 3. Run the main Flutter application, wrapped by the corrected lifecycle monitor
  runApp(const AppLifecycleMonitor(
    child: BirdFeederApp(),
  ));
}

// --- WIDGET FOR LIFECYCLE MONITORING ---
class AppLifecycleMonitor extends StatefulWidget {
  final Widget child; 
  const AppLifecycleMonitor({super.key, required this.child}); 
  
  @override
  State<AppLifecycleMonitor> createState() => _AppLifecycleMonitorState();
}

class _AppLifecycleMonitorState extends State<AppLifecycleMonitor> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // Start listening to app lifecycle changes
    WidgetsBinding.instance.addObserver(this);
    // Start listening to Pi heartbeat
    PiConnectionService().startListening();
    // Set status to open immediately on startup
    _updateAppStatus(true);
  }

  @override
  void dispose() {
    // Stop listening to app lifecycle changes
    WidgetsBinding.instance.removeObserver(this);
    // Set status to closed when the app is completely disposed
    _updateAppStatus(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // App is visible and running
        _updateAppStatus(true);
        break;
      case AppLifecycleState.paused:
        // App is in the background
      case AppLifecycleState.hidden:
        // App is still alive but not visible (Android/Web/Desktop)
      case AppLifecycleState.detached:
        // Engine is detached (terminating)
        // For inactive/paused/hidden/detached, we close the stream
        _updateAppStatus(false);
        break;
      case AppLifecycleState.inactive:
        // iOS only, temporary interruption (like phone call)
        break;
    }
  }

  /// Updates both 'app_is_open' and, if closing, forcefully disables 'streaming_enabled'.
  void _updateAppStatus(bool isOpen) async {
    try {
      final db = FirebaseFirestore.instance;

      // 1. Update app_is_open status
      await db.doc(StatusPaths.appIsOpen)
        .set(
          {
            'open': isOpen,
            'timestamp': FieldValue.serverTimestamp()
          },
          SetOptions(merge: true)
        );

      // 2. CRITICAL: If the app is closing (isOpen=false), forcefully disable streaming
      // This ensures the camera server is reliably stopped when the client goes away.
      if (!isOpen) {
         await db.doc(StatusPaths.streamingEnabled)
          .set(
            {
              // Force disable streaming to save power/resources on the Pi
              'enabled': false,
              'timestamp': FieldValue.serverTimestamp()
            },
            SetOptions(merge: true)
          );
      }

    } catch (e) {
      // Log the error but don't disrupt the app if the write fails
      print('FIREBASE ERROR: Could not update app status to $isOpen: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Render the main application structure
    return widget.child;
  }
}
// --- END WIDGET ---

class BirdFeederApp extends StatelessWidget {
  const BirdFeederApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bird Feeder Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'Inter',
        useMaterial3: true,
        // Define a simple color scheme
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          primary: Colors.deepPurple,
          secondary: Colors.amber,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.deepPurple,
          foregroundColor: Colors.white,
          elevation: 4,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}