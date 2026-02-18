import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math';
import '../config/firebase_paths.dart';
import '../services/pi_connection_service.dart';

/// This screen manages the live stream through:
/// 1. Toggling the stream state via Firestore ('status/streaming_enabled').
/// 2. Establishing a TCP connection to the server when the stream is enabled.
/// 3. Rendering the JPEG stream data received from the TCP socket.
class LiveFeedScreen extends StatefulWidget {
  const LiveFeedScreen({super.key});

  @override
  State<LiveFeedScreen> createState() => _LiveFeedScreenState();
}

class _LiveFeedScreenState extends State<LiveFeedScreen> {
  // --- Configuration Constants ---
  static const int streamPort = 8000;
  
  // --- TCP Command Definitions ---
  // Matches Python server's CMD_PREFIX (0x01) and CMD_SNAPSHOT (0x01)
  static final Uint8List CMD_SNAPSHOT_REQUEST = Uint8List.fromList([0x01, 0x01]);

  // --- Socket and Stream State Variables ---
  Socket? _socket;
  String _connectionStatus = 'Disconnected';
  Uint8List? _currentFrameBytes;
  bool _isConnecting = false;

  // --- Border Animation 

  double _borderPulse = 1.0;
  Timer? _pulseTimer;
  
  // --- UI/Metadata State ---
  bool _isStreamingEnabled = false;
  String _streamResolution = 'N/A';
  String _snapshotResolution = 'N/A';
  
  // --- Test Capture State ---
  String? _testCaptureUrl;
  String? _selectedThumbnailUrl;
  bool _isTestCaptureLoading = false;
  String? _testCaptureError;
  final _testCaptureTransformController = TransformationController();

  // Firestore listeners
  StreamSubscription? _statusSubscription;
  StreamSubscription? _configSubscription;
  StreamSubscription? _testCaptureSubscription;

  // --- Buffer Management for Stream ---
  final List<int> _readBuffer = [];
  int _frameSize = 0;
  final Duration _frameInterval = const Duration(milliseconds: 1000 ~/ 20); // 20 FPS

  @override
  void initState() {
    super.initState();
    _startFirebaseListeners();
    // This is not in the immersive fullscreen but in the main tab view, 
    // so we don't need to change SystemChrome.
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _configSubscription?.cancel();
    _testCaptureSubscription?.cancel();
    _pulseTimer?.cancel();
    _testCaptureTransformController.dispose();
    _disconnectSocket();
    super.dispose();
  }

  // --- Firebase/Config Methods ---

  void _startFirebaseListeners() {
    // 1. Listen for the streaming status toggle
    final streamingStatusDoc = FirebaseFirestore.instance.doc(StatusPaths.streamingEnabled);
    _statusSubscription = streamingStatusDoc.snapshots().listen((snapshot) {
      if (snapshot.exists && snapshot.data() != null) {
        final data = snapshot.data()!;
        final newStatus = data['enabled'] as bool? ?? false;
        
        // Only run connection/disconnection logic if the state has genuinely changed
        if (newStatus != _isStreamingEnabled) {
          setState(() {
            _isStreamingEnabled = newStatus;
          });
          if (_isStreamingEnabled) {
            // Call async after build to ensure UI can render “Connecting”
            Future.microtask(() => _connectSocket());
          } else {
            _disconnectSocket();
          }

        }
      } else {
         // Default to off if document doesn't exist
         setState(() { _isStreamingEnabled = false; });
      }
    }, onError: (error) {
      print("Error listening to streaming status: $error");
    });

    // Helper function to convert a list/array of resolution numbers to a string
    String _formatResolution(dynamic res) {
      // Check if the data is a List with exactly two elements (Width and Height)
      if (res is List && res.length == 2) {
        return '${res[0]} x ${res[1]}';
      }
      else return 'N/A';
    }


    // 2. Listen for configuration updates to show metadata
    final configDoc = FirebaseFirestore.instance.doc(ConfigPaths.settings);
    _configSubscription = configDoc.snapshots().listen((snapshot) {
      if (snapshot.exists && snapshot.data() != null) {
        final data = snapshot.data()!;
        setState(() {
          _streamResolution = _formatResolution(data['stream_resolution']);
          _snapshotResolution = _formatResolution(data['snapshot_resolution']);
        });
      }
    }, onError: (error) {
      print("Error listening to config: $error");
    });

    // 3. Listen for test capture results
    final testCaptureDoc = FirebaseFirestore.instance.doc(StatusPaths.testCapture);
    _testCaptureSubscription = testCaptureDoc.snapshots().listen((snapshot) {
      if (snapshot.exists && snapshot.data() != null) {
        final data = snapshot.data()!;
        final requested = data['requested'] as bool? ?? false;
        final imageUrl = data['imageUrl'] as String?;
        final error = data['error'] as String?;

        setState(() {
          _isTestCaptureLoading = requested;
          _testCaptureError = error;
          if (!requested && imageUrl != null && imageUrl.isNotEmpty) {
            _testCaptureUrl = imageUrl;
            _selectedThumbnailUrl = null;
            _testCaptureTransformController.value = Matrix4.identity();
          }
        });
      }
    }, onError: (error) {
      print("Error listening to test capture status: $error");
    });
  }

  Future<void> _toggleStreaming() async {
    final newStatus = !_isStreamingEnabled;
    setState(() {
      _isConnecting = newStatus;
    });

    try {
      await FirebaseFirestore.instance.doc(StatusPaths.streamingEnabled).set(
        {
          'enabled': newStatus,
          'timestamp': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      // State will be updated by the listener
      setState(() {
        _isConnecting = false;
      });
    } catch (e) {
      print('FIREBASE ERROR: Could not toggle streaming status: $e');
      setState(() {
        _isConnecting = false;
      });
      _showSimpleMessage(context, 'Error', 'Failed to update streaming status in Firestore.');
    }
  }

  // --- TCP Socket Methods ---

  Future<void> _connectSocket() async {
  _disconnectSocket(); // Ensure any old connection is closed first

  // Immediately reflect "Connecting" in UI
  setState(() {
    _connectionStatus = 'Connecting';
  });
  _startBorderPulse(); // 💡 Start breathing effect


  // Trigger a short rebuild after 300ms so the spinner becomes visible
  Future.delayed(const Duration(milliseconds: 300), () {
    if (mounted && _connectionStatus == 'Connecting') setState(() {});
  });

  const maxWaitTime = Duration(seconds: 20); // wait up to 20s for server
  final startTime = DateTime.now();

  while (mounted && _isStreamingEnabled) {
    try {
      _socket = await Socket.connect(
        PiConnectionService().ipAddress, 
        streamPort,
        timeout: const Duration(seconds: 5)
        );

      if (!mounted) return;

      // If successful:
      setState(() {
        _connectionStatus = 'Connected';
      });

      _stopBorderPulse(); // 💡 Stop breathing when done

      _socket!.listen(
        _handleData,
        onError: (e) {
          print("Socket error: $e");
          _disconnectSocket();
          _stopBorderPulse(); // 💡 Stop breathing when done
          _showSimpleMessage(
              context, 'Connection Lost', 'The stream connection was lost.');
        },
        onDone: () {
          print("Socket closed by server.");
          _disconnectSocket();
          _stopBorderPulse(); // 💡 Stop breathing when done
        },
        cancelOnError: true,
      );

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });

      return; // ✅ connected successfully — stop retrying
    } catch (e) {
      print("Connection attempt failed: $e");
      await Future.delayed(const Duration(seconds: 2));
      final elapsed = DateTime.now().difference(startTime);
      if (elapsed > maxWaitTime) {
        if (!mounted) return;
        _disconnectSocket();
        _stopBorderPulse(); 
        _showSimpleMessage(context, 'Error',
            'Failed to connect to $PiConnectionService().ipAddress:$streamPort after waiting ${elapsed.inSeconds}s.');
        return;
      }
    }
  }
  }


  void _disconnectSocket() {
    if (_socket != null) {
      _socket!.close().catchError((_) {}); // Safely close
      _socket = null;
    }
    setState(() {
      _connectionStatus = 'Disconnected';
      _currentFrameBytes = null; // Clear frame when disconnected
      _readBuffer.clear();
      _frameSize = 0;
    });
  }

  void _handleData(Uint8List data) {
    _readBuffer.addAll(data);
    _processBuffer();
  }

  void _processBuffer() {
    while (_readBuffer.length >= 4) {
      if (_frameSize == 0) {
        // Read the 4-byte frame size (little-endian)
        _frameSize = ByteData.sublistView(Uint8List.fromList(_readBuffer.sublist(0, 4))).getUint32(0, Endian.little);
        _readBuffer.removeRange(0, 4);
      }

      if (_frameSize > 0 && _readBuffer.length >= _frameSize) {
        // We have a full frame
        final frameBytes = Uint8List.fromList(_readBuffer.sublist(0, _frameSize));
        _readBuffer.removeRange(0, _frameSize);

        // Update UI with the new frame, adhering to UI_FRAME_RATE limit
        // Since we don't have a Timer/Scheduler here, we'll rely on the
        // socket data rate, which is acceptable for simple JPEG streams.
        // If performance is an issue, we'd throttle this setState.
        setState(() {
          _currentFrameBytes = frameBytes;
        });
        
        _frameSize = 0; // Reset for the next frame
      } else {
        break; 
      }
    }
  }

  Future<void> _takeSnapshot(BuildContext context) async {
    if (_socket == null || _connectionStatus != 'Connected') {
      _showSimpleMessage(context, 'Error', 'Not connected to the server.');
      return;
    }

    try {
      _socket!.add(CMD_SNAPSHOT_REQUEST);
      _showSimpleMessage(context, 'Snapshot Requested', 'A high-resolution snapshot is being uploaded to Firebase Storage.');
      
      // The server will send a 1-byte reply ('S' for success, 'F' for failure)
      // We are ignoring the reply here for simplicity, trusting the server to log errors.
    } catch (e) {
      print('SNAPSHOT ERROR: Could not send command: $e');
      _showSimpleMessage(context, 'Error', 'Failed to send snapshot request to the server.');
    }
  }
  
  // --- Test Capture Methods ---

  Future<void> _requestTestCapture() async {
    if (_isTestCaptureLoading) return; // Debounce

    // Check if Pi is online
    if (!PiConnectionService().isOnline) {
      if (mounted) {
        _showSimpleMessage(context, 'Pi Offline', 'Cannot take test photo — Pi is not responding.');
      }
      return;
    }

    setState(() {
      _isTestCaptureLoading = true;
      _testCaptureError = null;
    });

    try {
      await FirebaseFirestore.instance.doc(StatusPaths.testCapture).set({
        'requested': true,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error requesting test capture: $e');
      setState(() {
        _isTestCaptureLoading = false;
      });
      if (mounted) {
        _showSimpleMessage(context, 'Error', 'Failed to request test capture.');
      }
    }
  }

  // --- UI Helper Methods ---
  
  // Helper for simple messages/toasts
  void _showSimpleMessage(BuildContext context, String title, String content) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        '$title: $content',
        style: const TextStyle(color: Colors.white),
      ),
      backgroundColor: Colors.deepPurple,
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // Original helper (for the Config Screen, kept for compatibility)
  Widget _buildMetadataRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // NEW: Compact metadata row for the bottom bar
  Widget _buildCompactMetadataRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  // NEW: Consolidated bottom control bar
  Widget _buildControlBar(BuildContext context) {
    final buttonColor = _isStreamingEnabled
        ? Colors.red.shade700
        : Theme.of(context).colorScheme.secondary;
    final isConnected = _socket != null && _connectionStatus == 'Connected';

    // 1. Diagnostics (Condensed)
    final Widget condensedDiagnostics = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCompactMetadataRow('Stream Res:', _streamResolution, Colors.white),
        _buildCompactMetadataRow('Snapshot Res:', _snapshotResolution, Colors.white),
        _buildCompactMetadataRow('Status:', _connectionStatus, isConnected ? Colors.green : Colors.red),
      ],
    );

    // 2. Control Buttons
    final Widget controlButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Test Capture Button (works without stream)
        _isTestCaptureLoading
            ? const SizedBox(
                width: 30,
                height: 30,
                child: Padding(
                  padding: EdgeInsets.all(4.0),
                  child: CircularProgressIndicator(
                    color: Colors.amber,
                    strokeWidth: 2.5,
                  ),
                ),
              )
            : IconButton(
                onPressed: _requestTestCapture,
                icon: const Icon(Icons.photo_camera_outlined),
                color: Colors.amber,
                iconSize: 30,
                tooltip: 'Test Capture (no stream needed)',
              ),
        const SizedBox(width: 6),
        // Snapshot Button (requires stream)
        IconButton(
          onPressed: isConnected ? () => _takeSnapshot(context) : null,
          icon: const Icon(Icons.camera_alt),
          color: Theme.of(context).colorScheme.secondary,
          disabledColor: Colors.grey.shade600,
          iconSize: 30,
          tooltip: 'Take Snapshot',
        ),
        const SizedBox(width: 6),
        // Toggle Stream Button
        IconButton(
          onPressed: _isConnecting ? null : _toggleStreaming,
          icon: Icon(_isStreamingEnabled ? Icons.stop : Icons.play_arrow),
          color: buttonColor,
          disabledColor: Colors.grey.shade600,
          iconSize: 30,
          tooltip: _isStreamingEnabled ? 'Stop Stream' : 'Start Stream',
        ),
      ],
    );

    // The entire bar container
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      // Semi-transparent black bar
      color: Colors.black54, 
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Diagnostics on the left, takes remaining space
          Expanded(child: condensedDiagnostics),
          // Buttons on the right
          controlButtons,
        ],
      ),
    );
  }
  
  // Placeholder for when the stream is off or disconnected
  Widget _buildPlaceholder() {
    // Show test capture preview when stream is off and we have an image
    final displayUrl = _selectedThumbnailUrl ?? _testCaptureUrl;
    if (!_isStreamingEnabled && displayUrl != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // Zoomable image
          InteractiveViewer(
            transformationController: _testCaptureTransformController,
            boundaryMargin: EdgeInsets.zero,
            minScale: 1.0,
            maxScale: 6.0,
            child: CachedNetworkImage(
              imageUrl: displayUrl,
              fit: BoxFit.contain,
              placeholder: (context, url) => const Center(
                child: CircularProgressIndicator(color: Colors.white54),
              ),
              errorWidget: (context, url, error) => const Center(
                child: Icon(Icons.broken_image, color: Colors.white38, size: 60),
              ),
            ),
          ),
          // Label overlay
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Test Capture',
                style: TextStyle(color: Colors.amber, fontSize: 11),
              ),
            ),
          ),
          // Zoom reset button
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.zoom_out_map, color: Colors.white70, size: 20),
              tooltip: 'Reset zoom',
              onPressed: () => _testCaptureTransformController.value = Matrix4.identity(),
            ),
          ),
          // Error overlay
          if (_testCaptureError != null)
            Positioned(
              bottom: 8,
              left: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Error: $_testCaptureError',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
        ],
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _isStreamingEnabled ? Icons.wifi_off : Icons.videocam_off,
            color: Colors.white38,
            size: 60,
          ),
          const SizedBox(height: 10),
          Text(
            _isStreamingEnabled
                ? 'Waiting for video data...\nCheck server connection.'
                : 'Stream is currently stopped.\nTap the play button to start.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 16),
          ),
          if (!_isStreamingEnabled) ...[
            const SizedBox(height: 20),
            Text(
              'Use the test capture button to preview camera settings',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.amber.withValues(alpha: 0.6), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  // Recent test captures thumbnail row
  Widget _buildTestCaptureThumbnails() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(LogPaths.testCaptures)
          .orderBy('timestamp', descending: true)
          .limit(5)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const SizedBox.shrink();
        }

        final docs = snapshot.data!.docs;
        return Container(
          color: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          height: 72,
          child: Row(
            children: [
              const Text(
                'Recent:',
                style: TextStyle(color: Colors.white54, fontSize: 10),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final url = data['imageUrl'] as String? ?? '';
                    final isSelected = _selectedThumbnailUrl == url;

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedThumbnailUrl = isSelected ? null : url;
                          _testCaptureTransformController.value = Matrix4.identity();
                        });
                      },
                      child: Container(
                        width: 80,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isSelected ? Colors.amber : Colors.white24,
                            width: isSelected ? 2 : 1,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        clipBehavior: Clip.hardEdge,
                        child: CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Colors.white38,
                              ),
                            ),
                          ),
                          errorWidget: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image, color: Colors.white24, size: 20),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  //Border Animation functions

void _startBorderPulse() {
  _pulseTimer?.cancel();
  _pulseTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
    setState(() {
      final t = DateTime.now().millisecondsSinceEpoch / 500;
      _borderPulse = 1.0 + 0.5 * sin(t);
    });
  });
}

void _stopBorderPulse() {
  _pulseTimer?.cancel();
  _pulseTimer = null;
  setState(() => _borderPulse = 1.0);
}

// Define pulsing colors for "Connecting"
final Color darkOrange = Color(0xFFFF0000); // deep orange
final Color lightAmber = Color(0xFFFFFF00); // bright amber

@override
Widget build(BuildContext context) {
  return Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            children: [
              // Live feed area fills nearly all available height
             Expanded(
  child: LayoutBuilder(
    builder: (context, constraints) {
      final bool isConnecting = _connectionStatus == 'Connecting';
      final bool isConnected = _connectionStatus == 'Connected';
      final bool hasFrame = _currentFrameBytes != null;

      // Pick border color based on connection state
      final Color borderColor = isConnected
          ? Colors.greenAccent
          : isConnecting
              ? Color.lerp(darkOrange, lightAmber, (sin(DateTime.now().millisecondsSinceEpoch / 600) * 0.5 + 0.5))!
              : Colors.redAccent;


      return Stack(
        children: [
          // Background remains dark
          Container(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            color: Colors.black,
          ),

          // Animated border & feed
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            width: constraints.maxWidth,
            height: constraints.maxHeight,
              decoration: BoxDecoration(
              color: Colors.black, // Keeps the inside always dark
              border: Border.all(
                color: borderColor.withOpacity(0.9),
                width: 4,
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: borderColor.withOpacity(0.7),
                  blurRadius: 10 + 20 * (_borderPulse - 1.0).abs(),
                  spreadRadius: 3 + 4 * (_borderPulse - 1.0).abs(),
                  offset: const Offset(0, 0),
                ),
              ],
            ),

            clipBehavior: Clip.hardEdge,
            child: isConnected && hasFrame
                ? Image.memory(
                    _currentFrameBytes!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                  )
                : _buildPlaceholder(),
          ),


          // Overlay spinner while connecting
          if (isConnecting)
            Container(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 12),
                    Text(
                      "Connecting to camera...",
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  ),
),


              // Test capture thumbnails (only shown when not streaming)
              if (!_isStreamingEnabled)
                _buildTestCaptureThumbnails(),

              // Control bar stays at bottom
              SafeArea(
                top: false,
                child: _buildControlBar(context),
              ),
            ],
          );
        },
      ),
    ),
  );
}

 
}