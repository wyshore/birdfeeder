// lib/screens/home_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../config/firebase_paths.dart';
import 'activity_screen.dart';
import 'catalog_screen.dart';
import 'live_feed_screen.dart';
import 'system_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  // The screens for the bottom navigation bar
  static final List<Widget> _widgetOptions = <Widget>[
    const ActivityScreen(),

    const CatalogScreen(),
    
    const LiveFeedScreen(),

    const SystemScreen(),

  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

    @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            // 1. App Title
            const Text(
              'Bird Feeder Camera',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 10),

            // 2. Online/Offline Status Dot
            StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance.doc(StatusPaths.heartbeat).snapshots(),
              builder: (context, snapshot) {
                bool isOnline = false;
                if (snapshot.hasData && snapshot.data!.exists) {
                  final data = snapshot.data!.data() as Map<String, dynamic>;
                  final status = data['status'] as String?;
                  final Timestamp? lastSeen = data['last_seen'];
                  if (lastSeen != null && status == 'online') {
                    isOnline = DateTime.now().difference(lastSeen.toDate()).inSeconds < 60;
                  }
                }
                return Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: isOnline ? Colors.green : Colors.red,
                    shape: BoxShape.circle,
                    boxShadow: isOnline
                        ? [BoxShadow(color: Colors.green.withOpacity(0.5), blurRadius: 4)]
                        : [],
                  ),
                );
              },
            ),

            const Spacer(), // Pushes the battery info to the right side

            // 3. Dynamic Battery Level (Nested Data Fix)
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('logs')
                  .doc('energy')
                  .collection('data')
                  .orderBy('timestamp', descending: true)
                  .limit(1)
                  .snapshots(),
              builder: (context, snapshot) {
                double batteryLevel = 0;
                
                if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
                  final data = snapshot.data!.docs.first.data() as Map<String, dynamic>;
                  
                  // Drilling down into the 'battery' map from your screenshot
                  if (data.containsKey('battery')) {
                    final batteryMap = data['battery'] as Map<String, dynamic>;
                    // Accessing 'percent' inside the 'battery' map
                    batteryLevel = (batteryMap['percent'] ?? 0).toDouble();
                  }
                }

                // Determine icon and color based on charge
                IconData batteryIcon = Icons.battery_full;
                Color iconColor = Colors.green;

                if (batteryLevel <= 20) {
                  batteryIcon = Icons.battery_alert;
                  iconColor = Colors.red;
                } else if (batteryLevel <= 60) {
                  batteryIcon = Icons.battery_3_bar;
                  iconColor = Colors.orange;
                }

                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${batteryLevel.toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 4),
                    Icon(batteryIcon, color: iconColor, size: 22),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      // Display the selected screen
      body: _widgetOptions.elementAt(_selectedIndex),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.camera_alt),
            label: 'Activity',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.auto_stories),
            label: 'Catalog',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.videocam),
            label: 'Live Feed',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'System',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Colors.grey[600],
        onTap: _onItemTapped,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}
