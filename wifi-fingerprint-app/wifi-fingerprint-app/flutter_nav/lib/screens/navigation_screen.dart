import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/nav_models.dart';
import '../services/api_service.dart';
import '../services/wifi_scanner_service.dart';

class NavigationScreen extends StatefulWidget {
  final String backendUrl;

  const NavigationScreen({super.key, required this.backendUrl});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  static const double svgOriginalWidth = 1262.0;
  static const double svgOriginalHeight = 800.0;

  late NavigationApiService _apiService;
  late final WifiScannerService _scannerService;
  late String _currentBackendUrl;

  // Selected floor in the floor picker (0, 1, 2)
  int _selectedFloor = 0;

  // Available room destinations from GET /api/rooms
  List<RoomDestination> _rooms = [];
  bool _isLoadingRooms = false;
  RoomDestination? _selectedDestination;
  bool _accessibleRouting = false;

  // Positioning
  UserLocation? _userLocation;
  Offset? _pendingTapSvg;
  Timer? _wifiScanTimer;
  bool _isScanning = false;

  // Rolling WiFi scan history: up to 3 most recent scans
  // Each entry is a map of BSSID -> RSSI, plus BSSID -> SSID lookup
  final List<Map<String, double>> _scanHistory = [];
  final Map<String, String> _bssidSsidMap = {};

  // Active navigation route
  RouteResult? _currentRoute;
  bool _isLoadingRoute = false;

  // Status & error messages
  String? _errorMessage;
  String? _statusMessage;

  static const String _prefBackendUrlKey = 'pref_nav_backend_url';

  @override
  void initState() {
    super.initState();
    _currentBackendUrl = widget.backendUrl;
    _apiService = NavigationApiService(baseUrl: _currentBackendUrl);
    _scannerService = WifiScannerService();

    _loadSavedBackendUrl();
    _initPositioning();
  }

  Future<void> _loadSavedBackendUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString(_prefBackendUrlKey);
      if (savedUrl != null && savedUrl.trim().isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _currentBackendUrl = savedUrl.trim();
          _apiService = NavigationApiService(baseUrl: _currentBackendUrl);
        });
      }
    } catch (_) {}
    _loadRooms();
  }

  @override
  void dispose() {
    _wifiScanTimer?.cancel();
    super.dispose();
  }

  String _floorSvgAsset(int floor) {
    switch (floor) {
      case 1:
        return 'assets/floorplans/sos/SOS-floor-1-first.svg';
      case 2:
        return 'assets/floorplans/sos/SOS-floor-2-second.svg';
      case 0:
      default:
        return 'assets/floorplans/sos/SOS-floor-0-ground.svg';
    }
  }

  Future<void> _loadRooms() async {
    setState(() => _isLoadingRooms = true);
    final resp = await _apiService.getRooms(building: "SOS");
    if (!mounted) return;

    if (resp.success && resp.data != null) {
      setState(() {
        _rooms = resp.data!;
        _isLoadingRooms = false;
        _errorMessage = null;
      });
    } else {
      setState(() {
        _isLoadingRooms = false;
        _errorMessage = resp.errorMessage ?? 'Failed to connect to backend';
      });
    }
  }

  void _initPositioning() {
    if (!Platform.isAndroid) {
      setState(() {
        _statusMessage = 'iOS: WiFi scanning unavailable (Apple restriction). Tap map to set your location.';
      });
      return;
    }

    // Request permissions and kick off scanning every 10 seconds
    _scannerService.requestPermission().then((granted) {
      if (!mounted) return;
      if (!granted) {
        setState(() {
          _errorMessage = 'Location permission is required for WiFi positioning.';
        });
        return;
      }

      // Initial scan
      _scanAndLocate();

      // Periodic scan about every 10 seconds
      _wifiScanTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        _scanAndLocate();
      });
    });
  }

  Future<void> _scanAndLocate() async {
    if (_isScanning || !Platform.isAndroid) return;
    _isScanning = true;

    try {
      await _scannerService.requestFreshScan();
      // Brief pause to allow Android scan results to update
      await Future.delayed(const Duration(milliseconds: 500));
      final rawReadings = await _scannerService.getCurrentReadings();

      if (!mounted) {
        _isScanning = false;
        return;
      }

      if (rawReadings.isEmpty) {
        setState(() {
          _errorMessage = 'No WiFi scan results. Ensure Wi-Fi and Location are turned on.';
        });
        _isScanning = false;
        return;
      }

      // Record BSSIDs and SSIDs
      final currentScanMap = <String, double>{};
      bool hasStudentAp = false;

      for (final ap in rawReadings) {
        final bssid = (ap['bssid'] as String? ?? '').trim().toLowerCase();
        final ssid = (ap['ssid'] as String? ?? '').trim();
        final rssi = (ap['rssi'] as num?)?.toDouble() ?? -100.0;

        if (bssid.isEmpty) continue;
        currentScanMap[bssid] = rssi;
        _bssidSsidMap[bssid] = ssid;

        if (ssid.toLowerCase() == 'student') {
          hasStudentAp = true;
        }
      }

      if (!hasStudentAp) {
        setState(() {
          _errorMessage = 'No "Student" access points found in scan.';
        });
        _isScanning = false;
        return;
      }

      // Maintain rolling history of up to 3 scans
      _scanHistory.add(currentScanMap);
      if (_scanHistory.length > 3) {
        _scanHistory.removeAt(0);
      }

      // Average RSSI per BSSID across the last 3 scans
      final bssidSum = <String, double>{};
      final bssidCount = <String, int>{};

      for (final scan in _scanHistory) {
        scan.forEach((bssid, rssi) {
          bssidSum[bssid] = (bssidSum[bssid] ?? 0.0) + rssi;
          bssidCount[bssid] = (bssidCount[bssid] ?? 0) + 1;
        });
      }

      final averagedReadings = <Map<String, dynamic>>[];
      bssidSum.forEach((bssid, totalRssi) {
        final count = bssidCount[bssid]!;
        final avgRssi = totalRssi / count;
        averagedReadings.add({
          'bssid': bssid,
          'ssid': _bssidSsidMap[bssid] ?? 'Student',
          'rssi': avgRssi.round(),
        });
      });

      // Send to backend with chosen floor_number
      final resp = await _apiService.locateUser(
        building: "SOS",
        floorNumber: _selectedFloor,
        readings: averagedReadings,
      );

      if (!mounted) {
        _isScanning = false;
        return;
      }

      if (resp.success && resp.data != null) {
        final loc = resp.data!;
        setState(() {
          _userLocation = UserLocation(
            x: loc.x,
            y: loc.y,
            floorNumber: loc.floorNumber,
            isManual: false,
            timestamp: DateTime.now(),
          );
          _errorMessage = null;
        });

        // If a destination is already selected, update route
        if (_selectedDestination != null) {
          _fetchRoute();
        }
      } else {
        setState(() {
          _errorMessage = resp.errorMessage ?? 'Position estimation failed';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Wi-Fi locate error: $e';
        });
      }
    } finally {
      _isScanning = false;
    }
  }

  void _handleMapTap(Offset localPos, double containerWidth, double containerHeight) {
    final scale = min(containerWidth / svgOriginalWidth, containerHeight / svgOriginalHeight);
    final dx = (containerWidth - svgOriginalWidth * scale) / 2.0;
    final dy = (containerHeight - svgOriginalHeight * scale) / 2.0;

    final svgX = (localPos.dx - dx) / scale;
    final svgY = (localPos.dy - dy) / scale;

    if (svgX >= 0 && svgX <= svgOriginalWidth && svgY >= 0 && svgY <= svgOriginalHeight) {
      setState(() {
        _pendingTapSvg = Offset(svgX, svgY);
      });
    }
  }

  void _confirmManualPosition() {
    if (_pendingTapSvg == null) return;
    setState(() {
      _userLocation = UserLocation(
        x: _pendingTapSvg!.dx,
        y: _pendingTapSvg!.dy,
        floorNumber: _selectedFloor,
        isManual: true,
        timestamp: DateTime.now(),
      );
      _pendingTapSvg = null;
      _errorMessage = null;
    });

    if (_selectedDestination != null) {
      _fetchRoute();
    }
  }

  Future<void> _fetchRoute() async {
    if (_selectedDestination == null) return;

    if (_userLocation == null) {
      setState(() {
        _errorMessage = 'Starting position unknown: tap the map and choose "I\'m here" or wait for Wi-Fi locate.';
      });
      return;
    }

    setState(() {
      _isLoadingRoute = true;
      _errorMessage = null;
    });

    final resp = await _apiService.getRoute(
      building: "SOS",
      fromPos: {
        'x': _userLocation!.x,
        'y': _userLocation!.y,
        'floor_number': _userLocation!.floorNumber,
      },
      toNode: _selectedDestination!.nodeId,
      accessible: _accessibleRouting,
    );

    if (!mounted) return;

    if (resp.success && resp.data != null) {
      setState(() {
        _currentRoute = resp.data!;
        _isLoadingRoute = false;
        _errorMessage = null;
      });
    } else {
      setState(() {
        _isLoadingRoute = false;
        _errorMessage = resp.errorMessage ?? 'Could not find a route to ${_selectedDestination!.displayName}';
      });
    }
  }

  void _clearRoute() {
    setState(() {
      _selectedDestination = null;
      _currentRoute = null;
      _pendingTapSvg = null;
    });
  }

  void _showBackendSettingsDialog() {
    final controller = TextEditingController(text: _currentBackendUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Backend Server URL', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the Flask backend URL (IP and port 5050):',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  labelText: 'Server URL',
                  labelStyle: const TextStyle(color: Colors.white60),
                  hintText: 'http://172.17.63.95:5050',
                  hintStyle: const TextStyle(color: Colors.white38),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Quick presets:',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ActionChip(
                    label: const Text('Wi-Fi (172.17.63.95)', style: TextStyle(fontSize: 11)),
                    backgroundColor: const Color(0xFF334155),
                    onPressed: () => controller.text = 'http://172.17.63.95:5050',
                  ),
                  ActionChip(
                    label: const Text('USB/ADB (127.0.0.1)', style: TextStyle(fontSize: 11)),
                    backgroundColor: const Color(0xFF334155),
                    onPressed: () => controller.text = 'http://127.0.0.1:5050',
                  ),
                  ActionChip(
                    label: const Text('Emulator (10.0.2.2)', style: TextStyle(fontSize: 11)),
                    backgroundColor: const Color(0xFF334155),
                    onPressed: () => controller.text = 'http://10.0.2.2:5050',
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final newUrl = controller.text.trim();
              if (newUrl.isNotEmpty) {
                Navigator.pop(ctx);
                try {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(_prefBackendUrlKey, newUrl);
                } catch (_) {}
                if (!mounted) return;
                setState(() {
                  _currentBackendUrl = newUrl;
                  _apiService = NavigationApiService(baseUrl: _currentBackendUrl);
                  _errorMessage = null;
                });
                _loadRooms();
                if (Platform.isAndroid) _scanAndLocate();
              }
            },
            child: const Text('Save & Reconnect'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SOS Indoor Navigation', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: const Color(0xFF0F172A),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          // Accessible routing toggle
          IconButton(
            tooltip: _accessibleRouting ? 'Accessible route (elevator only)' : 'Standard route (stairs allowed)',
            icon: Icon(
              Icons.accessible,
              color: _accessibleRouting ? Colors.lightBlueAccent : Colors.white60,
            ),
            onPressed: () {
              setState(() {
                _accessibleRouting = !_accessibleRouting;
              });
              if (_selectedDestination != null) {
                _fetchRoute();
              }
            },
          ),
          IconButton(
            tooltip: 'Refresh rooms',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _loadRooms();
              if (Platform.isAndroid) _scanAndLocate();
            },
          ),
          IconButton(
            tooltip: 'Server Settings',
            icon: const Icon(Icons.settings),
            onPressed: _showBackendSettingsDialog,
          ),
        ],
      ),
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Column(
          children: [
            // 1. Destination Search Box & Floor Picker Row
            _buildControlHeader(),

            // Error / Status banners
            if (_errorMessage != null) _buildErrorBanner(_errorMessage!),
            if (_statusMessage != null && _errorMessage == null) _buildStatusBanner(_statusMessage!),

            // 2. Interactive SVG Map
            Expanded(
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final height = constraints.maxHeight;
                      final scale = min(width / svgOriginalWidth, height / svgOriginalHeight);
                      final dx = (width - svgOriginalWidth * scale) / 2.0;
                      final dy = (height - svgOriginalHeight * scale) / 2.0;

                      return InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 5.0,
                        boundaryMargin: const EdgeInsets.all(20),
                        child: SizedBox(
                          width: width,
                          height: height,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (details) => _handleMapTap(details.localPosition, width, height),
                            child: Stack(
                              children: [
                                // SVG Floor Plan
                                Positioned(
                                  left: dx,
                                  top: dy,
                                  width: svgOriginalWidth * scale,
                                  height: svgOriginalHeight * scale,
                                  child: SvgPicture.asset(
                                    _floorSvgAsset(_selectedFloor),
                                    fit: BoxFit.fill,
                                  ),
                                ),
                                // Polyline & Markers Overlay
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: MapOverlayPainter(
                                      scale: scale,
                                      dx: dx,
                                      dy: dy,
                                      displayedFloor: _selectedFloor,
                                      userLocation: _userLocation,
                                      pendingTap: _pendingTapSvg,
                                      route: _currentRoute,
                                      destination: _selectedDestination,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                  // Floating "I'm here" confirmation button when a point is tapped
                  if (_pendingTapSvg != null)
                    Positioned(
                      bottom: 16,
                      left: 20,
                      right: 20,
                      child: _buildTapConfirmationCard(),
                    ),

                  // Loading indicator
                  if (_isLoadingRoute || _isLoadingRooms)
                    const Positioned(
                      top: 12,
                      right: 12,
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.blueAccent),
                      ),
                    ),
                ],
              ),
            ),

            // 3. Navigation Steps & Distance Footer
            if (_currentRoute != null && _selectedDestination != null)
              _buildNavigationFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildControlHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(bottom: BorderSide(color: Color(0xFF334155), width: 1)),
      ),
      child: Column(
        children: [
          // Search box
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF475569)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: ButtonTheme(
                      alignedDropdown: true,
                      child: DropdownButton<RoomDestination>(
                        value: _selectedDestination,
                        hint: const Row(
                          children: [
                            Icon(Icons.search, size: 20, color: Colors.white54),
                            SizedBox(width: 8),
                            Text('Choose destination room...', style: TextStyle(color: Colors.white54, fontSize: 14)),
                          ],
                        ),
                        isExpanded: true,
                        dropdownColor: const Color(0xFF1E293B),
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                        items: _rooms.map((room) {
                          return DropdownMenuItem<RoomDestination>(
                            value: room,
                            child: Text(
                              room.displayName,
                              style: const TextStyle(color: Colors.white),
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: (RoomDestination? destination) {
                          setState(() {
                            _selectedDestination = destination;
                            _pendingTapSvg = null;
                          });
                          if (destination != null) {
                            _fetchRoute();
                          } else {
                            _clearRoute();
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),
              if (_selectedDestination != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Clear route',
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: _clearRoute,
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),

          // Floor picker buttons row
          Row(
            children: [
              const Text(
                'Floor:',
                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      for (final fl in [0, 1, 2])
                        Padding(
                          padding: const EdgeInsets.only(right: 6.0),
                          child: ChoiceChip(
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            labelPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                            label: Text(
                              'Floor $fl',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: _selectedFloor == fl ? Colors.white : Colors.white70,
                              ),
                            ),
                            selected: _selectedFloor == fl,
                            selectedColor: const Color(0xFF2563EB),
                            backgroundColor: const Color(0xFF0F172A),
                            side: BorderSide(
                              color: _selectedFloor == fl ? const Color(0xFF3B82F6) : const Color(0xFF475569),
                            ),
                            onSelected: (selected) {
                              if (selected) {
                                setState(() {
                                  _selectedFloor = fl;
                                });
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Positioning indicator badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: _userLocation?.isManual == true
                      ? Colors.amber.withValues(alpha: 0.2)
                      : (_userLocation != null ? Colors.blue.withValues(alpha: 0.2) : Colors.grey.withValues(alpha: 0.2)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _userLocation?.isManual == true ? Icons.touch_app : Icons.wifi,
                      size: 14,
                      color: _userLocation?.isManual == true ? Colors.amberAccent : Colors.lightBlueAccent,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _userLocation != null
                          ? (_userLocation!.isManual ? 'Manual Pos' : 'Floor ${_userLocation!.floorNumber}')
                          : 'No pos',
                      style: TextStyle(
                        fontSize: 12,
                        color: _userLocation?.isManual == true ? Colors.amberAccent : Colors.lightBlueAccent,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    final isConnectionError = message.contains('http') || message.contains('Backend') || message.contains('timed out');
    return Container(
      width: double.infinity,
      color: Colors.red.shade900.withValues(alpha: 0.85),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          if (isConnectionError) ...[
            const SizedBox(width: 6),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Colors.amberAccent,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _showBackendSettingsDialog,
              child: const Text('Change IP', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => setState(() => _errorMessage = null),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(String message) {
    return Container(
      width: double.infinity,
      color: Colors.blueGrey.shade800,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.lightBlueAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTapConfirmationCard() {
    return Card(
      color: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.blueAccent)),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.pin_drop, color: Colors.amberAccent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Set current position here?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(
                    'Floor $_selectedFloor (${_pendingTapSvg!.dx.round()}, ${_pendingTapSvg!.dy.round()})',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _pendingTapSvg = null),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
              ),
              onPressed: _confirmManualPosition,
              child: const Text("I'm here"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationFooter() {
    final route = _currentRoute!;
    final destination = _selectedDestination!;

    // Current floor's segment
    RouteSegment? currentSegment;
    for (final seg in route.segments) {
      if (seg.floorNumber == _selectedFloor) {
        currentSegment = seg;
        break;
      }
    }

    // Determine next floor if route crosses floors
    int? nextFloor;
    String stepInstruction = '';

    if (currentSegment != null) {
      if (currentSegment.exitConnector != null) {
        final connectorName = currentSegment.exitConnector!
            .replaceAll(RegExp(r'^f\d+-'), '')
            .replaceAll('-', ' ')
            .toUpperCase();

        final currentIdx = route.segments.indexOf(currentSegment);
        if (currentIdx + 1 < route.segments.length) {
          nextFloor = route.segments[currentIdx + 1].floorNumber;
          stepInstruction = 'Go to $connectorName, then switch to Floor $nextFloor';
        }
      } else {
        stepInstruction = 'Walk along path to ${destination.displayName}';
      }
    } else {
      stepInstruction = 'Route passes through floor $_selectedFloor. Switch floors to view segment.';
    }

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(top: BorderSide(color: Color(0xFF334155), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Distance & Destination summary line
          Row(
            children: [
              const Icon(Icons.navigation, color: Colors.lightBlueAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${route.totalLengthMeters.toStringAsFixed(1)} m remaining • ${destination.displayName}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_accessibleRouting)
                const Padding(
                  padding: EdgeInsets.only(left: 6.0),
                  child: Tooltip(
                    message: 'Elevator route only',
                    child: Icon(Icons.accessible, size: 16, color: Colors.lightBlueAccent),
                  ),
                ),
            ],
          ),

          // Multi-floor step instruction and floor switch button
          if (stepInstruction.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    stepInstruction,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                if (nextFloor != null)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: Text('Floor $nextFloor'),
                    onPressed: () {
                      setState(() {
                        _selectedFloor = nextFloor!;
                      });
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class MapOverlayPainter extends CustomPainter {
  final double scale;
  final double dx;
  final double dy;
  final int displayedFloor;
  final UserLocation? userLocation;
  final Offset? pendingTap;
  final RouteResult? route;
  final RoomDestination? destination;

  MapOverlayPainter({
    required this.scale,
    required this.dx,
    required this.dy,
    required this.displayedFloor,
    this.userLocation,
    this.pendingTap,
    this.route,
    this.destination,
  });

  Offset _svgToScreen(double svgX, double svgY) {
    return Offset(svgX * scale + dx, svgY * scale + dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw route polyline for the currently displayed floor
    if (route != null) {
      for (final seg in route!.segments) {
        if (seg.floorNumber == displayedFloor && seg.steps.isNotEmpty) {
          final path = Path();
          final startPoint = _svgToScreen(seg.steps[0].x, seg.steps[0].y);
          path.moveTo(startPoint.dx, startPoint.dy);

          for (int i = 1; i < seg.steps.length; i++) {
            final pt = _svgToScreen(seg.steps[i].x, seg.steps[i].y);
            path.lineTo(pt.dx, pt.dy);
          }

          // Route outline / glow
          final glowPaint = Paint()
            ..color = const Color(0xFF2563EB).withValues(alpha: 0.35)
            ..strokeWidth = 10.0
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..style = PaintingStyle.stroke;
          canvas.drawPath(path, glowPaint);

          // Route solid line
          final linePaint = Paint()
            ..color = const Color(0xFF38BDF8)
            ..strokeWidth = 4.5
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..style = PaintingStyle.stroke;
          canvas.drawPath(path, linePaint);

          // Connector badges
          if (seg.exitConnector != null && seg.steps.isNotEmpty) {
            final exitPt = _svgToScreen(seg.steps.last.x, seg.steps.last.y);
            _drawConnectorMarker(canvas, exitPt, Colors.amber, isExit: true);
          }
          if (seg.entryConnector != null && seg.steps.isNotEmpty) {
            final entryPt = _svgToScreen(seg.steps.first.x, seg.steps.first.y);
            _drawConnectorMarker(canvas, entryPt, Colors.greenAccent, isExit: false);
          }
        }
      }
    }

    // 2. Draw destination pin (if destination is on the currently displayed floor)
    if (destination != null && destination!.floorNumber == displayedFloor) {
      double destX = destination!.x ?? 0.0;
      double destY = destination!.y ?? 0.0;

      // If x, y wasn't provided directly on destination, look up matching step
      if (destX == 0 && destY == 0 && route != null && route!.nodes.isNotEmpty) {
        final last = route!.nodes.last;
        if (last.floorNumber == displayedFloor) {
          destX = last.x;
          destY = last.y;
        }
      }

      if (destX > 0 && destY > 0) {
        final destScreen = _svgToScreen(destX, destY);
        _drawDestinationMarker(canvas, destScreen, destination!.displayName);
      }
    }

    // 3. Draw pending tap marker
    if (pendingTap != null) {
      final tapScreen = _svgToScreen(pendingTap!.dx, pendingTap!.dy);
      final tapPaint = Paint()
        ..color = Colors.amberAccent
        ..style = PaintingStyle.fill;
      canvas.drawCircle(tapScreen, 8, tapPaint);
      final tapBorder = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawCircle(tapScreen, 8, tapBorder);
    }

    // 4. Draw user position blue dot (if on currently displayed floor)
    if (userLocation != null && userLocation!.floorNumber == displayedFloor) {
      final userScreen = _svgToScreen(userLocation!.x, userLocation!.y);

      // Translucent halo
      final haloPaint = Paint()
        ..color = const Color(0xFF38BDF8).withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(userScreen, 18, haloPaint);

      // White outline
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawCircle(userScreen, 9, borderPaint);

      // Inner blue dot
      final dotPaint = Paint()
        ..color = userLocation!.isManual ? Colors.amberAccent : const Color(0xFF0284C7)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(userScreen, 9, dotPaint);
    }
  }

  void _drawConnectorMarker(Canvas canvas, Offset pos, Color color, {required bool isExit}) {
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(pos, 10, fill);
    canvas.drawCircle(pos, 10, stroke);
  }

  void _drawDestinationMarker(Canvas canvas, Offset pos, String label) {
    final pinPaint = Paint()
      ..color = const Color(0xFFEF4444)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pos, 10, pinPaint);

    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(pos, 10, border);
  }

  @override
  bool shouldRepaint(covariant MapOverlayPainter oldDelegate) {
    return oldDelegate.scale != scale ||
        oldDelegate.dx != dx ||
        oldDelegate.dy != dy ||
        oldDelegate.displayedFloor != displayedFloor ||
        oldDelegate.userLocation != userLocation ||
        oldDelegate.pendingTap != pendingTap ||
        oldDelegate.route != route ||
        oldDelegate.destination != destination;
  }
}
