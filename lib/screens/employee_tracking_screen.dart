import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import '../services/foreground_task_handler.dart';
import '../services/firebase_service.dart';
import 'dart:convert'; // for json encode/decode
import 'dart:math';  
import 'LoginScreen.dart';
import 'EmployeeTripsScreen.dart'; // Import the EmployeeTripsScreen

class EmployeeTrackingScreen extends StatefulWidget {
  const EmployeeTrackingScreen({Key? key}) : super(key: key);

  @override
  State<EmployeeTrackingScreen> createState() => _EmployeeTrackingScreenState();
}

class _EmployeeTrackingScreenState extends State<EmployeeTrackingScreen> {
  ReceivePort? _receivePort;
  bool _isServiceRunning = false;
  bool _isLoading = false;
  GoogleMapController? _mapController;
  LatLng _currentLatLng = const LatLng(0, 0);
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  bool _isInitialLocationFetched = false;
  LatLng? _startLocation;
  LatLng? _endLocation;
  double _totalDistance = 0.0;
  String _employeeName = "";
  String _employeeId = "";
  String? _currentTripId;
  Timer? _reconnectTimer;
  LatLng? _lastSavedFirebasePoint;
final double _distanceThresholdKm = 0.5; // half km
final List<LatLng> _tripPoints = [];



  // Firebase real-time listeners
  StreamSubscription<DatabaseEvent>? _tripDataSubscription;
  DatabaseReference? _databaseRef;

  // Simple polyline management
  LatLng? _previousLocation;
  final String _previousLocationKey = 'previous_location';

  final String _serviceRunningKey = 'service_running';
  final String _tripDataKey = 'trip_data';
  final String _currentTripIdKey = 'current_trip_id';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initializeApp();
      _loadEmployeeData();
    });
  }


   Future<void> _loadEmployeeData() async {
    final prefs = await SharedPreferences.getInstance();
    final userJson = prefs.getString('user'); // fetch logged-in user
    if (userJson != null) {
      final userMap = Map<String, dynamic>.from(jsonDecode(userJson));
      setState(() {
        _employeeName = userMap['fullname'] ?? "";
        _employeeId = userMap['employeeId'] ?? "";
      });
    }
  }

  Future<void> _initializeApp() async {
    await _requestPermissions();
    await FirebaseService.initialize();
    _databaseRef = FirebaseDatabase.instance.ref();
    _initForegroundTask();
    _loadEmployeeData();
    await _loadTripData();
    await _checkActiveTripInFirebase();

    final bool isServiceRunning = await FlutterForegroundTask.isRunningService;
    if (isServiceRunning) {
      _registerReceivePort(FlutterForegroundTask.receivePort);

      _sendDataToService({
        'action': 'get_status',
        'tripId': _currentTripId,
        'employeeId': _employeeId,
        'employeeName': _employeeName,
      });

      setState(() => _isServiceRunning = true);
      _startReconnectTimer();
    }

    await _getCurrentLocation();
  }

  // Setup Firebase real-time listeners for trip data only
  void _setupFirebaseRealtimeListeners(String tripId) {
    _tripDataSubscription?.cancel();

    // Listen to trip data changes (distance, current location)
    _tripDataSubscription = _databaseRef?.child('trips/$tripId').onValue.listen((event) {
      if (event.snapshot.value != null) {
        final Map<dynamic, dynamic> data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        _handleRealtimeTripData(Map<String, dynamic>.from(data));
      }
    });

    print("✅ Firebase real-time listener activated for trip: $tripId");
  }

  // Handle real-time trip data updates with simple polyline drawing
  void _handleRealtimeTripData(Map<String, dynamic> tripData) {
    if (mounted) {
      setState(() {
        // Update total distance
        _totalDistance = (tripData['totalDistance'] ?? 0.0).toDouble();
        
        // Update current location marker and draw polyline
        if (tripData['currentLocation'] != null) {
          final current = tripData['currentLocation'];
          final currentLatLng = LatLng(
            (current['latitude'] ?? 0.0).toDouble(),
            (current['longitude'] ?? 0.0).toDouble()
          );
          _updateLocationOnMap(currentLatLng.latitude, currentLatLng.longitude);
          
          // Draw line from previous to current location
          _drawLineToCurrentLocation(currentLatLng);
        }

        // Update start location if not set
        if (_startLocation == null && tripData['startLocation'] != null) {
          final start = tripData['startLocation'];
          _startLocation = LatLng(
            (start['latitude'] ?? 0.0).toDouble(),
            (start['longitude'] ?? 0.0).toDouble()
          );
          _addMarker(_startLocation!, 'start_point', 'Start Point',
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen));
          
          // Set as previous location when starting
          _previousLocation = _startLocation;
          _savePreviousLocation(_previousLocation!);
        }

        // Update status
        _isServiceRunning = tripData['status'] == 'in_progress';
      });
    }
  }

 
void _drawLineToCurrentLocation(LatLng currentLocation) async {
  if (_previousLocation == null) {
    _previousLocation = await _loadPreviousLocation();
  }

  // Add current point to the trip points list
  _tripPoints.add(currentLocation);

  // Save previous location
  _previousLocation = currentLocation;
  _savePreviousLocation(currentLocation);

  // Update the single polyline with all points
  setState(() {
    _polylines.removeWhere((polyline) => polyline.polylineId.value == 'full_trip');
    _polylines.add(Polyline(
      polylineId: const PolylineId('full_trip'),
      points: List.from(_tripPoints), // Use all accumulated points
      color: Colors.blue,
      width: 5,
      geodesic: true,
    ));
  });
}



Future<void> _savePointToFirebase(LatLng point) async {
  if (_currentTripId == null) return;

  final DatabaseReference tripPointsRef = _databaseRef!.child('trips/$_currentTripId/points');

  // Push new point
  final newPointRef = tripPointsRef.push();
  await newPointRef.set({
    'latitude': point.latitude,
    'longitude': point.longitude,
    'timestamp': ServerValue.timestamp,
  });

  // Optional: Add a marker for each 0.5 km point
  setState(() {
    _markers.add(Marker(
      markerId: MarkerId('point_${newPointRef.key}'),
      position: point,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      infoWindow: const InfoWindow(title: '0.5 km Point'),
    ));
  });
}


  // Calculate distance between two points in meters
  double _calculateDistance(LatLng from, LatLng to) {
    const double earthRadius = 6371000; // meters
    
    double dLat = _toRadians(to.latitude - from.latitude);
    double dLng = _toRadians(to.longitude - from.longitude);
    
    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(from.latitude)) * 
        cos(_toRadians(to.latitude)) *
        sin(dLng / 2) * sin(dLng / 2);
    
    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    
    return earthRadius * c;
  }

  double _toRadians(double degrees) {
    return degrees * pi / 180;
  }

  // Save/load previous location
  Future<void> _savePreviousLocation(LatLng location) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_previousLocationKey, 
      json.encode({'lat': location.latitude, 'lng': location.longitude}));
  }

  Future<LatLng?> _loadPreviousLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final String? locationJson = prefs.getString(_previousLocationKey);
    
    if (locationJson != null) {
      final Map<String, dynamic> locationData = json.decode(locationJson);
      return LatLng(locationData['lat'], locationData['lng']);
    }
    return null;
  }

  void _startReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_isServiceRunning) {
        _reconnectToService();
      } else {
        timer.cancel();
      }
    });
  }

Future<void> _checkActiveTripInFirebase() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    String? savedTripId = prefs.getString(_currentTripIdKey);

    if (savedTripId != null) {
      final snapshot = await FirebaseService.getTripData(savedTripId);

      if (snapshot != null && snapshot['status'] == 'in_progress') {
        setState(() {
          _currentTripId = savedTripId;
          _isServiceRunning = true;
          _totalDistance = (snapshot['totalDistance'] ?? 0.0).toDouble();
        });

        // Setup real-time listeners for the active trip
        _setupFirebaseRealtimeListeners(savedTripId);

        if (snapshot['startLocation'] != null) {
          final start = snapshot['startLocation'];
          _startLocation = LatLng(
            (start['latitude'] ?? 0.0).toDouble(),
            (start['longitude'] ?? 0.0).toDouble()
          );
          _addMarker(_startLocation!, 'start_point', 'Start Point',
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen));
        }

        if (snapshot['currentLocation'] != null) {
          final current = snapshot['currentLocation'];
          final currentLatLng = LatLng(
            (current['latitude'] ?? 0.0).toDouble(),
            (current['longitude'] ?? 0.0).toDouble()
          );
          _updateLocationOnMap(currentLatLng.latitude, currentLatLng.longitude);
        }

        // Load saved points from Firebase and create single polyline
        final pointsSnapshot = await _databaseRef!.child('trips/$savedTripId/points').get();
        if (pointsSnapshot.exists) {
          final pointsData = Map<String, dynamic>.from(pointsSnapshot.value as Map);
          
          // Sort points by timestamp to ensure correct order
          final sortedPoints = <Map<String, dynamic>>[];
          pointsData.forEach((key, value) {
            final point = value as Map;
            sortedPoints.add({
              'key': key,
              'latitude': point['latitude'],
              'longitude': point['longitude'],
              'timestamp': point['timestamp'] ?? key,
            });
          });
          
          // Sort by timestamp
          sortedPoints.sort((a, b) {
            final t1 = a['timestamp'].toString();
            final t2 = b['timestamp'].toString();
            return t1.compareTo(t2);
          });
          
          // Clear existing points and add sorted points
          _tripPoints.clear();
          for (var point in sortedPoints) {
            final latLng = LatLng(
              (point['latitude'] ?? 0.0).toDouble(),
              (point['longitude'] ?? 0.0).toDouble(),
            );
            _tripPoints.add(latLng);

            // Add markers for each 0.5 km point
            _markers.add(Marker(
              markerId: MarkerId('point_${point['key']}'),
              position: latLng,
              icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
              infoWindow: const InfoWindow(title: '0.5 km Point'),
            ));
          }

          // Draw single polyline with all points
          setState(() {
            _polylines.clear();
            _polylines.add(Polyline(
              polylineId: const PolylineId('full_trip'),
              points: List.from(_tripPoints),
              color: Colors.blue,
              width: 5,
              geodesic: true,
            ));
          });
        }

        // Load previous location to continue polyline
        _previousLocation = await _loadPreviousLocation();
        print("✅ Restored active trip from Firebase: $savedTripId");
      } else {
        await _clearTripData();
      }
    }
  } catch (e) {
    print('Error checking active trip in Firebase: $e');
  }
}

  Future<void> _reconnectToService() async {
    try {
      final bool isServiceRunning = await FlutterForegroundTask.isRunningService;
      if (isServiceRunning && _receivePort == null) {
        _registerReceivePort(FlutterForegroundTask.receivePort);
        _sendDataToService({'action': 'get_status'});
      }
    } catch (e) {
      print('Error reconnecting to service: $e');
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _tripDataSubscription?.cancel();
    _closeReceivePort();
    super.dispose();
  }

  Future<void> _loadTripData() async {
    final prefs = await SharedPreferences.getInstance();
    
    _isServiceRunning = prefs.getBool(_serviceRunningKey) ?? false;
    _currentTripId = prefs.getString(_currentTripIdKey);
    
    // Load previous location
    _previousLocation = await _loadPreviousLocation();
    
    final String? tripDataJson = prefs.getString(_tripDataKey);
    if (tripDataJson != null) {
      final Map<String, dynamic> tripData = json.decode(tripDataJson);
      
      if (tripData['startLocation'] != null) {
        final Map<String, dynamic> point = tripData['startLocation'];
        _startLocation = LatLng(point['lat'], point['lng']);
        _addMarker(_startLocation!, 'start_point', 'Start Point', 
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen));
      }
      
      if (tripData['endLocation'] != null) {
        final Map<String, dynamic> point = tripData['endLocation'];
        _endLocation = LatLng(point['lat'], point['lng']);
        _addMarker(_endLocation!, 'end_point', 'End Point', 
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed));
      }
      
      _totalDistance = (tripData['totalDistance'] ?? 0.0).toDouble();
    }
    
    setState(() {});
  }

  Future<void> _saveTripData({
    LatLng? startLocation,
    LatLng? endLocation,
    double? totalDistance,
    bool? isServiceRunning,
    String? tripId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    
    final String? existingTripDataJson = prefs.getString(_tripDataKey);
    Map<String, dynamic> tripData = {};
    
    if (existingTripDataJson != null) {
      tripData = json.decode(existingTripDataJson);
    }
    
    if (startLocation != null) {
      tripData['startLocation'] = {
        'lat': startLocation.latitude, 
        'lng': startLocation.longitude
      };
    }
    
    if (endLocation != null) {
      tripData['endLocation'] = {
        'lat': endLocation.latitude, 
        'lng': endLocation.longitude
      };
    }
    
    if (totalDistance != null) {
      tripData['totalDistance'] = totalDistance;
    }
    
    if (tripId != null) {
      tripData['tripId'] = tripId;
      tripData['employeeId'] = _employeeId;
      tripData['employeeName'] = _employeeName;
    }
    
    if (isServiceRunning != null) {
      await prefs.setBool(_serviceRunningKey, isServiceRunning);
    }
    
    if (tripId != null) {
      _currentTripId = tripId;
      await prefs.setString(_currentTripIdKey, tripId);
    }
    
    await prefs.setString(_tripDataKey, json.encode(tripData));
  }

  Future<void> _clearTripData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serviceRunningKey);
    await prefs.remove(_tripDataKey);
    await prefs.remove(_currentTripIdKey);
    await prefs.remove(_previousLocationKey);
    
    // Cancel Firebase listeners
    _tripDataSubscription?.cancel();
    
    setState(() {
      _currentTripId = null;
      _totalDistance = 0.0;
      _previousLocation = null;
    });
    
    if (await FlutterForegroundTask.isRunningService) {
      _sendDataToService({'action': 'clear_data'});
    }
  }

  Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
      if (permission != LocationPermission.whileInUse && 
          permission != LocationPermission.always) {
        throw Exception('Location permissions are required');
      }
    }

    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    final NotificationPermission status =
        await FlutterForegroundTask.checkNotificationPermission();
    if (status != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'foreground_service',
        channelName: 'Foreground Service',
        channelDescription: 'Live location updates in background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  bool _registerReceivePort(ReceivePort? newReceivePort) {
    if (newReceivePort == null) return false;
    _closeReceivePort();
    _receivePort = newReceivePort;
    _receivePort?.listen(_onReceiveData);
    return true;
  }

  void _closeReceivePort() {
    _receivePort?.close();
    _receivePort = null;
  }

  Future<void> _sendDataToService(Map<String, dynamic> data) async {
    try {
      FlutterForegroundTask.sendData(data);
    } catch (e) {
      print('Error sending data to service: $e');
    }
  }

  void _onReceiveData(dynamic data) {
    if (data is Map<String, dynamic>) {
      if (data['type'] == 'status') {
        setState(() {
          _totalDistance = (data['totalDistance'] ?? 0.0).toDouble();
          _isServiceRunning = data['isRunning'] ?? false;
          _isLoading = false;
        });
        return;
      }
      
      double lat = data["latitude"] ?? 0;
      double lng = data["longitude"] ?? 0;
      double distanceInKm = (data["totalDistance"] ?? 0.0).toDouble();
      
      final currentLatLng = LatLng(lat, lng);
      _updateLocationOnMap(lat, lng);
      _drawLineToCurrentLocation(currentLatLng);
      
      setState(() {
        _totalDistance = distanceInKm;
        _isLoading = false;
      });
    }
  }

  void _updateLocationOnMap(double lat, double lng) {
    final newLatLng = LatLng(lat, lng);
    setState(() {
      _currentLatLng = newLatLng;
      _markers.removeWhere((marker) => marker.markerId.value == 'current_location');
      _markers.add(Marker(
        markerId: const MarkerId('current_location'),
        position: newLatLng,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'Current Location'),
      ));
    });

    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(target: newLatLng, zoom: 17)),
    );
  }

  void _addMarker(LatLng position, String id, String title, BitmapDescriptor icon) {
    setState(() {
      _markers.add(Marker(
        markerId: MarkerId(id),
        position: position,
        icon: icon,
        infoWindow: InfoWindow(title: title),
      ));
    });
  }

  Future<void> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );
      _updateLocationOnMap(position.latitude, position.longitude);
      setState(() => _isInitialLocationFetched = true);
    } catch (e) {
      print("Error getting current location: $e");
    }
  }

  Future<void> _refreshServiceConnection() async {
    setState(() => _isLoading = true);

    try {
      final bool isServiceRunning = await FlutterForegroundTask.isRunningService;

      if (isServiceRunning) {
        _registerReceivePort(FlutterForegroundTask.receivePort);

        _sendDataToService({
          'action': 'get_status',
          'tripId': _currentTripId,
          'employeeId': _employeeId,
          'employeeName': _employeeName,
        });

        if (_currentTripId != null) {
          _setupFirebaseRealtimeListeners(_currentTripId!);
        }

        setState(() {
          _isServiceRunning = true;
          _isLoading = false;
        });

        _showSuccessSnackbar('Reconnected to live tracking service');
      } else {
        setState(() {
          _isServiceRunning = false;
          _isLoading = false;
        });
        _showErrorSnackbar('No active trip found');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showErrorSnackbar('Error refreshing connection: $e');
    }
  }

  Future<void> _startForegroundTask() async {
    setState(() => _isLoading = true);
    
    try {
      await _requestPermissions();
      await _clearRoute();
      
      final receivePort = FlutterForegroundTask.receivePort;
      final bool isPortRegistered = _registerReceivePort(receivePort);
      
      if (!isPortRegistered) {
        setState(() => _isLoading = false);
        _showErrorSnackbar('Failed to initialize communication with service');
        return;
      }

      ServiceRequestResult result;
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        await Future.delayed(const Duration(seconds: 1));
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );
      final startLatLng = LatLng(position.latitude, position.longitude);
      
      setState(() {
        _startLocation = startLatLng;
        _previousLocation = startLatLng;
        _addMarker(_startLocation!, 'start_point', 'Start Point', 
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen));
        _totalDistance = 0.0;
        _polylines.clear();
        _endLocation = null;
        _markers.removeWhere((marker) => marker.markerId.value == 'end_point');
      });

      // Save the starting location as previous location
      await _savePreviousLocation(startLatLng);

      final newTripId = DateTime.now().millisecondsSinceEpoch.toString();

      await FirebaseService.sendTripStart(
        tripId: newTripId,
        employeeId: _employeeId,
        employeeName: _employeeName,
        startLocation: startLatLng,
      );

      await _saveTripData(
        startLocation: _startLocation,
        totalDistance: 0.0,
        isServiceRunning: true,
        tripId: newTripId,
      );

      setState(() {
        _currentTripId = newTripId;
      });

      // Setup Firebase real-time listeners for the new trip
      _setupFirebaseRealtimeListeners(newTripId);

      result = await FlutterForegroundTask.startService(
        notificationTitle: 'Trip in Progress',
        notificationText: 'Distance: 0.00 km',
        callback: startCallback,
      );

      if (result.success) {
        setState(() {
          _isServiceRunning = true;
          _isLoading = false;
        });
        
        _startReconnectTimer();
        
        await Future.delayed(const Duration(seconds: 2));
        _sendDataToService({
          'action': 'get_status',
          'tripId': _currentTripId,
          'employeeId': _employeeId,
          'employeeName': _employeeName,
        });
      } else {
        setState(() => _isLoading = false);
        _showErrorSnackbar('Failed to start service: ${result.error}');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showErrorSnackbar('Error starting service: $e');
    }
  }

  Future<void> _stopForegroundTask() async {
    setState(() => _isLoading = true);
    
    try {
      _reconnectTimer?.cancel();
      
      // Cancel Firebase listeners
      _tripDataSubscription?.cancel();
      
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );
      final endLatLng = LatLng(position.latitude, position.longitude);
      
      setState(() {
        _endLocation = endLatLng;
        _addMarker(_endLocation!, 'end_point', 'End Point', 
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed));
      });

      await FirebaseService.sendTripEnd(
        tripId: _currentTripId!,
        endLocation: endLatLng,
        totalDistanceInKm: _totalDistance,
      );

      await _saveTripData(
        endLocation: _endLocation,
        isServiceRunning: false,
      );

      final result = await FlutterForegroundTask.stopService();
      if (result.success) {
        setState(() {
          _isServiceRunning = false;
          _isLoading = false;
        });
        _closeReceivePort();
        
        _showSuccessSnackbar('Trip stopped. Total distance: ${_totalDistance.toStringAsFixed(2)} km');
      } else {
        setState(() => _isLoading = false);
        _showErrorSnackbar('Failed to stop service: ${result.error}');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showErrorSnackbar('Error stopping service: $e');
    }
  }

  void _showErrorSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showSuccessSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }

 Future<void> _clearRoute() async {
  setState(() {
    _polylines.clear();
    _tripPoints.clear(); // Clear the points list
    _markers.removeWhere((marker) => 
      marker.markerId.value != 'current_location');
    _startLocation = null;
    _endLocation = null;
    _previousLocation = null;
    _totalDistance = 0.0;
    _currentTripId = null;
  });
  
  // Clear stored previous location
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_previousLocationKey);
  
  // Cancel Firebase listeners
  _tripDataSubscription?.cancel();
  
  await _clearTripData();
}

  @override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(
      title: const Text('Employee Trip Tracker'),
      backgroundColor: _isServiceRunning ? Colors.green[700] : Colors.blue[700],
      actions: [
        // Bike icon first
       IconButton(
  icon: const Icon(Icons.directions_bike, color: Colors.white),
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmployeeTripsScreen(
          employeeId: _employeeId, // your current logged-in employee
          employeeName: _employeeName,
        ),
      ),
    );
  },
  tooltip: 'My Trips',
),

        // Logout icon second
        IconButton(
          icon: const Icon(Icons.logout, color: Colors.white),
          tooltip: 'Logout',
          onPressed: () async {
            // Stop foreground service if running
            if (await FlutterForegroundTask.isRunningService) {
              await FlutterForegroundTask.stopService();
            }

            // Clear saved user data
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('user');
            await prefs.remove(_currentTripIdKey);
            await prefs.remove(_tripDataKey);
            await prefs.remove(_previousLocationKey);

            // Navigate to login screen
            if (context.mounted) {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => LoginScreen()),
                (route) => false,
              );
            }
          },
        ),
      ],
    ),
    body: Stack(
      children: [
        Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              color: _isServiceRunning ? Colors.green[50] : Colors.blue[50],
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Employee: $_employeeName', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                      Text('ID: $_employeeId', style: const TextStyle(color: Colors.black87)),
                      Text(
                        'Trip ID: ${_currentTripId ?? 'Not started'}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Distance: ${_totalDistance.toStringAsFixed(2)} km',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87),
                      ),
                      Text(
                        'Updated: ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: _isInitialLocationFetched ? _currentLatLng : const LatLng(0, 0),
                  zoom: _isInitialLocationFetched ? 17 : 2,
                ),
                markers: _markers,
                polylines: _polylines,
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
                onMapCreated: (controller) {
                  _mapController = controller;
                  if (_isInitialLocationFetched) {
                    _mapController?.animateCamera(
                      CameraUpdate.newCameraPosition(
                        CameraPosition(target: _currentLatLng, zoom: 17),
                      ),
                    );
                  }
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.all(10.0),
              color: Colors.grey[100],
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: _isServiceRunning || _isLoading ? null : _startForegroundTask,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(120, 50),
                    ),
                    child: _isLoading && !_isServiceRunning
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_arrow),
                              SizedBox(height: 4),
                              Text('Start Trip'),
                            ],
                          ),
                  ),
                  ElevatedButton(
                    onPressed: (!_isServiceRunning || _isLoading) ? null : _stopForegroundTask,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(120, 50),
                    ),
                    child: _isLoading && _isServiceRunning
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.stop),
                              SizedBox(height: 4),
                              Text('Stop Trip'),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_isLoading)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text('Processing...', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
}