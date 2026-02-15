import 'package:flutter/material.dart';
// Import the screens that will become the tabs
import 'settings_screen.dart';
import 'stats_screen.dart';

/// A combined screen using a DefaultTabController to switch between
/// the Settings and Stats functionality.
class SystemScreen extends StatelessWidget {
  const SystemScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // We use DefaultTabController to manage the state and logic for the tabs.
    return DefaultTabController(
      length: 2, // We have two tabs: Settings and Stats
      child: Scaffold(
        appBar: AppBar(
          title: const Text('System Control Panel'),
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Colors.white,
          elevation: 4,
          // The TabBar is placed in the AppBar's bottom property
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [
              Tab(icon: Icon(Icons.settings), text: 'Settings'),
              Tab(icon: Icon(Icons.show_chart), text: 'Energy Stats'),
            ],
          ),
        ),
        // The TabBarView holds the actual screen widgets corresponding to the tabs
        body: const TabBarView(
          children: [
            // Tab 1: Settings Screen
            SettingsScreen(),
            
            // Tab 2: Stats Screen (now modified to not include its own Scaffold)
            StatsScreen(),
          ],
        ),
      ),
    );
  }
}