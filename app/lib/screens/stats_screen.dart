import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/energy_data.dart'; 

/// The StatsScreen is now a StatefulWidget to manage the time range selection
/// NOTE: The Scaffold and AppBar were removed to allow it to be embedded in a TabBarView.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  String _selectedRange = 'Last 7 Days';
  int _durationHours = 168; // Default to 7 days (168 hours)

  final List<String> _rangeOptions = ['Last 24 Hours', 'Last 7 Days'];

  void _updateRange(String? newRange) {
    if (newRange != null && newRange != _selectedRange) {
      setState(() {
        _selectedRange = newRange;
        _durationHours = newRange == 'Last 24 Hours' ? 24 : 168;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final DateTime startTime =
        DateTime.now().subtract(Duration(hours: _durationHours));

    final String startTimeString = startTime.toIso8601String();

    final energyCollection = FirebaseFirestore.instance
        .collection('logs')
        .doc('energy')
        .collection('data')
        // Query the string field 'timestamp' against the string filter
        .where('timestamp', isGreaterThanOrEqualTo: startTimeString) 
        .orderBy('timestamp', descending: false);

    // Removed Scaffold and AppBar. Content starts directly with Padding.
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          // Display the dynamic title here, now that we don't have an AppBar
          Text('Energy Stats ($_selectedRange)', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.deepPurple)),
          const SizedBox(height: 16),
          // Dropdown to choose the time range
          Card(
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButton<String>(
                value: _selectedRange,
                icon: const Icon(Icons.arrow_drop_down),
                iconSize: 24,
                elevation: 16,
                isExpanded: true,
                style: const TextStyle(color: Colors.deepPurple, fontSize: 16, fontWeight: FontWeight.bold),
                underline: Container(height: 0),
                onChanged: _updateRange,
                items: _rangeOptions
                    .map<DropdownMenuItem<String>>((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: energyCollection.snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error loading data: ${snapshot.error}'));
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: Text('No energy data available for this period.'));
                }

                final data = snapshot.data!.docs
                    .map((doc) => EnergyData.fromFirestore(doc))
                    .toList();

                // Convert list of EnergyData to FlSpot data
                final List<FlSpot> batterySpots = data.map((e) {
                  final double xValue = e.timestamp.millisecondsSinceEpoch.toDouble();
                  final double yValue = e.batteryPercent; 
                  return FlSpot(xValue, yValue);
                }).toList();

                final List<FlSpot> solarSpots = data.map((e) {
                  final double xValue = e.timestamp.millisecondsSinceEpoch.toDouble();
                  final double yValue = e.chargeVoltage; 
                  return FlSpot(xValue, yValue);
                }).toList();

                return SingleChildScrollView(
                  child: Column(
                    children: [
                      _buildChartCard(
                        title: 'Battery Percentage (%)',
                        spots: batterySpots,
                        minY: 0,
                        maxY: 100,
                        durationHours: _durationHours,
                        lineColor: Colors.blueAccent,
                        showLeftTitles: true,
                        unitLabel: '%',
                      ),
                      const SizedBox(height: 20),
                      _buildChartCard(
                        title: 'Solar Panel Voltage (V)',
                        spots: solarSpots,
                        minY: 0,
                        maxY: 6, // Assuming max solar voltage is around 6V
                        durationHours: _durationHours,
                        lineColor: Colors.orange,
                        showLeftTitles: true,
                        unitLabel: 'V',
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartCard({
    required String title,
    required List<FlSpot> spots,
    required double minY,
    required double maxY,
    required int durationHours,
    required Color lineColor,
    required bool showLeftTitles,
    required String unitLabel,
  }) {
    // If no data, return an empty placeholder card
    if (spots.isEmpty) {
      return Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const SizedBox(height: 200, child: Center(child: Text('No data points to display.'))),
            ],
          ),
        ),
      );
    }
    
    // Find min and max time values for X-axis
    final double minX = spots.first.x;
    final double maxX = spots.last.x;
    // Calculate the interval for the X-axis titles based on the time range
    final double timeDifferenceMinutes = (maxX - minX) / (1000 * 60);
    // Use an interval that gives about 4-6 labels on the axis
    const double targetLabels = 5;
    // Calculate required interval in milliseconds to achieve targetLabels
    final double intervalMilliseconds = (timeDifferenceMinutes / targetLabels) * 60 * 1000;


    return Card(
      elevation: 5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8.0, bottom: 8.0),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xff37434d),
                ),
              ),
            ),
            SizedBox(
              height: 220,
              child: LineChart(
                LineChartData(
                  minX: minX,
                  maxX: maxX,
                  minY: minY,
                  maxY: maxY,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: (maxY / 5).roundToDouble(),
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: Colors.grey.shade200,
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final dateTime = DateTime.fromMillisecondsSinceEpoch(value.toInt());
                          String text;
                          if (durationHours <= 24) {
                            text = '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
                          } else {
                            text = '${dateTime.month}/${dateTime.day}';
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 6.0),
                            child: Text(text,
                                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                          );
                        },
                        interval: intervalMilliseconds,
                        reservedSize: 28,
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: showLeftTitles,
                        getTitlesWidget: (value, meta) {
                          return Text('${value.toInt()}$unitLabel',
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                              textAlign: TextAlign.left);
                        },
                        reservedSize: 38,
                        interval: (maxY / 5).roundToDouble(),
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border(
                      bottom: BorderSide(color: Colors.grey.shade300),
                      left: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => Colors.grey.shade800,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          final dt = DateTime.fromMillisecondsSinceEpoch(spot.x.toInt());
                          final dateStr =
                              '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                          final timeStr =
                              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                          return LineTooltipItem(
                            '$dateStr\n$timeStr\n${spot.y.toStringAsFixed(1)}$unitLabel',
                            const TextStyle(
                                color: Colors.white, fontSize: 11, height: 1.5),
                          );
                        }).toList();
                      },
                    ),
                    handleBuiltInTouches: true,
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      curveSmoothness: 0.3,
                      color: lineColor,
                      barWidth: 2.5,
                      isStrokeCapRound: true,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) =>
                            FlDotCirclePainter(
                          radius: 2.5,
                          color: lineColor,
                          strokeColor: Colors.white,
                          strokeWidth: 1,
                        ),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: lineColor.withValues(alpha: 0.12),
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