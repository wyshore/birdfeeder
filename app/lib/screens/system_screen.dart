import 'package:flutter/material.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';

class SystemScreen extends StatelessWidget {
  const SystemScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('System Control Panel'),
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Colors.white,
          elevation: 4,
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
        body: const TabBarView(
          children: [
            SettingsScreen(),
            StatsScreen(),
          ],
        ),
      ),
    );
  }
}
