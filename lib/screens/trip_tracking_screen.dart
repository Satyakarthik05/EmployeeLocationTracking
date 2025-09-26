import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class TripTrackingScreen extends StatefulWidget {
  final String tripId;

  const TripTrackingScreen({Key? key, required this.tripId}) : super(key: key);

  @override
  State<TripTrackingScreen> createState() => _TripTrackingScreenState();
}

class _TripTrackingScreenState extends State<TripTrackingScreen> {
  GoogleMapController? _mapController;
  LatLng _currentLatLng = const LatLng(0, 0);
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  bool _isLoading = true;
  bool _isTripActive = true;

  // Trip data
  LatLng? _startLocation;
  LatLng? _endLocation;
  double _totalDistance = 0.0;
  String _employeeName = "";
  String _employeeId = "";
  String _status = "";
  DateTime? _startTime;
  DateTime? _endTime;

  // Firebase
  DatabaseReference? _databaseRef;
  StreamSubscription<DatabaseEvent>? _tripDataSubscription;
  StreamSubscription<DatabaseEvent>? _pointsSubscription;
  StreamSubscription<DatabaseEvent>? _stopPointsSubscription;
  StreamSubscription<DatabaseEvent>? _connectionLostSubscription;

  // Data lists
  final List<LatLng> _tripPoints = [];
  final List<Map<String, dynamic>> _stopPoints = [];
  final List<Map<String, dynamic>> _connectionLostSegments = [];

  @override
  void initState() {
    super.initState();
    _initializeFirebase();
  }

  Future<void> _initializeFirebase() async {
    await Firebase.initializeApp();
    _databaseRef = FirebaseDatabase.instance.ref();
    _loadTripData();
    _setupRealtimeListeners();
  }

  void _setupRealtimeListeners() {
    // Listen to main trip data
    _tripDataSubscription = _databaseRef?.child('trips/${widget.tripId}').onValue.listen((event) {
      if (event.snapshot.value != null) {
        final Map<dynamic, dynamic> data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        _handleTripDataUpdate(Map<String, dynamic>.from(data));
      }
    });

    // Listen to path points (0.5km markers)
    _pointsSubscription = _databaseRef?.child('trips/${widget.tripId}/points').onValue.listen((event) {
      if (event.snapshot.value != null) {
        final Map<dynamic, dynamic> pointsData = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        _handlePointsUpdate(Map<String, dynamic>.from(pointsData));
      }
    });

    // Listen to stop points
    _stopPointsSubscription = _databaseRef?.child('trips/${widget.tripId}/stopPoints').onValue.listen((event) {
      if (event.snapshot.value != null) {
        final Map<dynamic, dynamic> stopsData = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        _handleStopPointsUpdate(Map<String, dynamic>.from(stopsData));
      }
    });

    // Listen to connection lost segments
    _connectionLostSubscription = _databaseRef?.child('trips/${widget.tripId}/connectionLost').onValue.listen((event) {
      if (event.snapshot.value != null) {
        final Map<dynamic, dynamic> lostData = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        _handleConnectionLostUpdate(Map<String, dynamic>.from(lostData));
      }
    });
  }

  void _handleTripDataUpdate(Map<String, dynamic> tripData) {
    if (mounted) {
      setState(() {
        // Basic trip info
        _employeeName = tripData['employeeName'] ?? "Unknown";
        _employeeId = tripData['employeeId'] ?? "Unknown";
        _totalDistance = (tripData['totalDistance'] ?? 0.0).toDouble();
        _status = tripData['status'] ?? "unknown";
        _isTripActive = _status == 'in_progress';

        // Start location and time
        if (tripData['startLocation'] != null) {
          final start = tripData['startLocation'];
          _startLocation = LatLng(
            (start['latitude'] ?? 0.0).toDouble(),
            (start['longitude'] ?? 0.0).toDouble(),
          );
          
          if (tripData['startTime'] != null) {
            _startTime = DateTime.parse(tripData['startTime']);
          }
        }

        // End location and time
        if (tripData['endLocation'] != null) {
          final end = tripData['endLocation'];
          _endLocation = LatLng(
            (end['latitude'] ?? 0.0).toDouble(),
            (end['longitude'] ?? 0.0).toDouble(),
          );
          
          if (tripData['endTime'] != null) {
            _endTime = DateTime.parse(tripData['endTime']);
          }
        }

        // Current location (for live tracking)
        if (_isTripActive && tripData['currentLocation'] != null) {
          final current = tripData['currentLocation'];
          final currentLatLng = LatLng(
            (current['latitude'] ?? 0.0).toDouble(),
            (current['longitude'] ?? 0.0).toDouble(),
          );
          _updateCurrentLocation(currentLatLng);
        }

        _isLoading = false;
      });

      _updateMapMarkers();
      _drawPolylines();
    }
  }

  void _handlePointsUpdate(Map<String, dynamic> pointsData) {
  _tripPoints.clear();

  // Convert and store with timestamp
  final List<Map<String, dynamic>> tempPoints = [];

  pointsData.forEach((key, value) {
    final point = Map<String, dynamic>.from(value);
    final latLng = LatLng(
      (point['latitude'] ?? 0.0).toDouble(),
      (point['longitude'] ?? 0.0).toDouble(),
    );
    tempPoints.add({
      "latLng": latLng,
      "timestamp": point['timestamp'] ?? key, // use timestamp or key
    });
  });

  // Sort by timestamp
  tempPoints.sort((a, b) {
    final t1 = a['timestamp'].toString();
    final t2 = b['timestamp'].toString();
    return t1.compareTo(t2);
  });

  // Store only LatLngs in order
  for (var p in tempPoints) {
    _tripPoints.add(p['latLng']);
  }

  if (mounted) {
    setState(() {
      _updatePathMarkers();
    });
    _drawPolylines();
  }
}

  void _handleStopPointsUpdate(Map<String, dynamic> stopsData) {
    _stopPoints.clear();
    
    stopsData.forEach((key, value) {
      final stop = Map<String, dynamic>.from(value);
      _stopPoints.add(stop);
    });

    if (mounted) {
      setState(() {
        _updateStopPointMarkers();
      });
    }
  }

void _handleConnectionLostUpdate(Map<String, dynamic> lostData) {
  _connectionLostSegments.clear();

  lostData.forEach((key, value) {
    final segment = Map<String, dynamic>.from(value);

    final from = segment['from'] != null ? Map<String, dynamic>.from(segment['from']) : null;
    final to = segment['to'] != null ? Map<String, dynamic>.from(segment['to']) : null;

    if (from != null && to != null) {
      // Store the segment properly
      _connectionLostSegments.add({
        "from": LatLng(
          (from['latitude'] ?? 0.0).toDouble(),
          (from['longitude'] ?? 0.0).toDouble(),
        ),
        "to": LatLng(
          (to['latitude'] ?? 0.0).toDouble(),
          (to['longitude'] ?? 0.0).toDouble(),
        ),
      });

      // Add marker for "from"
      _markers.add(Marker(
        markerId: MarkerId('connection_lost_from_$key'),
        position: _connectionLostSegments.last["from"] as LatLng,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(
          title: 'Connection Lost Start',
          snippet: 'Time: ${from['timestamp'] ?? ''}',
        ),
      ));

      // Add marker for "to"
      _markers.add(Marker(
        markerId: MarkerId('connection_lost_to_$key'),
        position: _connectionLostSegments.last["to"] as LatLng,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(
          title: 'Connection Lost End',
          snippet: 'Time: ${to['timestamp'] ?? ''}',
        ),
      ));
    }
  });

  if (mounted) {
    setState(() {});
    _drawPolylines(); // Redraw polylines after updating connection lost segments
  }
}


  void _updateCurrentLocation(LatLng currentLatLng) {
    _currentLatLng = currentLatLng;
    
    // Update or add current location marker
    _markers.removeWhere((marker) => marker.markerId.value == 'current_location');
    _markers.add(Marker(
      markerId: const MarkerId('current_location'),
      position: currentLatLng,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      infoWindow: const InfoWindow(title: 'Current Location'),
    ));

    // Move camera to current location if trip is active
    if (_isTripActive) {
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: currentLatLng, zoom: 17),
        ),
      );
    }
  }

  void _updateMapMarkers() {
    _markers.clear();

    // Start point marker
    if (_startLocation != null) {
      _markers.add(Marker(
        markerId: const MarkerId('start_point'),
        position: _startLocation!,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(title: 'Start Point\n${_startTime?.toString() ?? ''}'),
      ));
    }

    // End point marker
    if (_endLocation != null) {
      _markers.add(Marker(
        markerId: const MarkerId('end_point'),
        position: _endLocation!,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: 'End Point\n${_endTime?.toString() ?? ''}'),
      ));
    }

    _updatePathMarkers();
    _updateStopPointMarkers();
  }

  void _updatePathMarkers() {
    // Add 0.5km path points
    for (int i = 0; i < _tripPoints.length; i++) {
      _markers.add(Marker(
        markerId: MarkerId('path_point_$i'),
        position: _tripPoints[i],
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(title: 'Path Point ${i + 1}'),
      ));
    }
  }

  void _updateStopPointMarkers() {
    // Add stop points
    for (int i = 0; i < _stopPoints.length; i++) {
      final stop = _stopPoints[i];
      final latLng = LatLng(
        (stop['lat'] ?? stop['latitude'] ?? 0.0).toDouble(),
        (stop['lng'] ?? stop['longitude'] ?? 0.0).toDouble(),
      );
      
      final duration = stop['durationMinutes'] ?? 0;
      final startTime = stop['startTime'] != null ? DateTime.parse(stop['startTime']) : null;
      
      _markers.add(Marker(
        markerId: MarkerId('stop_point_$i'),
        position: latLng,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
        infoWindow: InfoWindow(
          title: 'Stop Point ${i + 1}',
          snippet: 'Duration: ${duration} minutes\n${startTime?.toString() ?? ''}',
        ),
      ));
    }
  }

 void _drawPolylines() {
  _polylines.clear();

  // Main trip route
  if (_tripPoints.isNotEmpty) {
    _polylines.add(Polyline(
      polylineId: const PolylineId('main_trip'),
      points: _tripPoints,
      color: Colors.blue,
      width: 5,
      geodesic: true,
    ));
  } else if (_startLocation != null && _endLocation != null) {
    _polylines.add(Polyline(
      polylineId: const PolylineId('main_trip_fallback'),
      points: [_startLocation!, _endLocation!],
      color: Colors.blue,
      width: 5,
      geodesic: true,
    ));
  }

  // Connection lost segments (red lines)
  for (int i = 0; i < _connectionLostSegments.length; i++) {
    final seg = _connectionLostSegments[i];
    final fromLatLng = seg["from"] as LatLng;
    final toLatLng = seg["to"] as LatLng;

    _polylines.add(Polyline(
      polylineId: PolylineId('connection_lost_$i'),
      points: [fromLatLng, toLatLng],
      color: Colors.red,
      width: 10,
      geodesic: true,
      zIndex: 1,
      // Remove patterns temporarily to test
      // patterns: [PatternItem.dash(20), PatternItem.gap(10)],
    ));
  }

  setState(() {});
}




  Future<void> _loadTripData() async {
    try {
      // Load main trip data
      final tripSnapshot = await _databaseRef?.child('trips/${widget.tripId}').get();
      if (tripSnapshot?.exists ?? false) {
        final tripData = Map<String, dynamic>.from(tripSnapshot!.value as Map);
        _handleTripDataUpdate(tripData);
      }

      // Load path points
      final pointsSnapshot = await _databaseRef?.child('trips/${widget.tripId}/points').get();
      if (pointsSnapshot?.exists ?? false) {
        final pointsData = Map<String, dynamic>.from(pointsSnapshot!.value as Map);
        _handlePointsUpdate(pointsData);
      }

      // Load stop points
      final stopsSnapshot = await _databaseRef?.child('trips/${widget.tripId}/stopPoints').get();
      if (stopsSnapshot?.exists ?? false) {
        final stopsData = Map<String, dynamic>.from(stopsSnapshot!.value as Map);
        _handleStopPointsUpdate(stopsData);
      }

      // Load connection lost data
      final lostSnapshot = await _databaseRef?.child('trips/${widget.tripId}/connectionLost').get();
      if (lostSnapshot?.exists ?? false) {
        final lostData = Map<String, dynamic>.from(lostSnapshot!.value as Map);
        _handleConnectionLostUpdate(lostData);
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading trip data: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _zoomToFitAllMarkers() {
    if (_markers.isEmpty) return;

    LatLngBounds bounds = _createBounds(_markers.map((m) => m.position).toList());
    
    _mapController?.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 100),
    );
  }

  LatLngBounds _createBounds(List<LatLng> positions) {
    double? minLat, maxLat, minLng, maxLng;
    
    for (final position in positions) {
      minLat = minLat == null ? position.latitude : (minLat < position.latitude ? minLat : position.latitude);
      maxLat = maxLat == null ? position.latitude : (maxLat > position.latitude ? maxLat : position.latitude);
      minLng = minLng == null ? position.longitude : (minLng < position.longitude ? minLng : position.longitude);
      maxLng = maxLng == null ? position.longitude : (maxLng > position.longitude ? maxLng : position.longitude);
    }
    
    return LatLngBounds(
      southwest: LatLng(minLat!, minLng!),
      northeast: LatLng(maxLat!, maxLng!),
    );
  }

  String _formatDuration(DateTime? start, DateTime? end) {
    if (start == null || end == null) return "N/A";
    
    final duration = end.difference(start);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    
    return '${hours}h ${minutes}m';
  }

  @override
  void dispose() {
    _tripDataSubscription?.cancel();
    _pointsSubscription?.cancel();
    _stopPointsSubscription?.cancel();
    _connectionLostSubscription?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Trip Tracking - ${widget.tripId}'),
        backgroundColor: _isTripActive ? Colors.orange : Colors.green,
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_out_map),
            onPressed: _zoomToFitAllMarkers,
            tooltip: 'Fit all markers',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadTripData,
            tooltip: 'Refresh data',
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: LatLng(0, 0),
              zoom: 2,
            ),
            markers: _markers,
            polylines: _polylines,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            onMapCreated: (controller) {
              _mapController = controller;
              // Wait a bit for data to load then zoom to markers
              Future.delayed(const Duration(seconds: 2), () {
                if (_markers.isNotEmpty) {
                  _zoomToFitAllMarkers();
                }
              });
            },
          ),
          
          if (_isLoading)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Loading trip data...', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          
          // Trip info panel
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Employee: $_employeeName (ID: $_employeeId)',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('Trip ID: ${widget.tripId}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    Text('Status: ${_status.toUpperCase()}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _isTripActive ? Colors.orange : Colors.green,
                        )),
                    Text('Distance: ${_totalDistance.toStringAsFixed(2)} km',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    if (_startTime != null)
                      Text('Start: ${_startTime?.toString() ?? "N/A"}'),
                    if (_endTime != null)
                      Text('End: ${_endTime?.toString() ?? "N/A"}'),
                    if (_startTime != null && _endTime != null)
                      Text('Duration: ${_formatDuration(_startTime, _endTime)}'),
                    
                    // Legend
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      children: [
                        _buildLegendItem(Colors.green, 'Start'),
                        _buildLegendItem(Colors.red, 'End'),
                        _buildLegendItem(Colors.orange, '0.5km Points'),
                        _buildLegendItem(Colors.purple, 'Stops'),
                        _buildLegendItem(Colors.blue, 'Route'),
                        _buildLegendItem(Colors.red, 'Connection Lost'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          color: color,
        ),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 10)),
      ],
    );
  }
}