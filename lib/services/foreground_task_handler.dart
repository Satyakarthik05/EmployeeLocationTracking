import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_service.dart';
import 'dart:convert';
import 'dart:math';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

class LocationTaskHandler extends TaskHandler {
  int _count = 0;
  StreamSubscription<Position>? _positionStream;
  List<LatLng> _polylinePoints = [];
  double _totalDistance = 0.0;
  LatLng? _previousPosition;
  bool _isMoving = false;
  Timer? _movementTimer;
  DateTime? _lastMovementTime;
  SendPort? _sendPort;
  bool _isRunning = true;
  String? _currentTripId;
  String? _employeeId;
  String? _employeeName;
  Timer? _firebaseUpdateTimer;
  bool _isFirebaseInitialized = false;
  double _lastSavedDistance = 0.0;

  // ----- Stop point tracking -----
  LatLng? _stopStartPosition;
  DateTime? _stopStartTime;
  bool _stopPointRecorded = false;
  bool _readyToRecordStop = false;
  List<LatLng> _recentPositions = [];
  double _stopAccumulatedDistance = 0.0;

  // ----- Stop-point timer -----
  Timer? _stopPointTimer;

  @override
  void onStart(DateTime timestamp, SendPort? sendPort) async {
    _sendPort = sendPort;
    _isRunning = true;

    await _initializeFirebase();
    await _loadTripData();
    _sendStatusUpdate();
    _startLocationTracking();
    _startFirebaseUpdateTimer();
    _startStopPointChecker(); // start the stop-point checker

    print('Service initialized. Initial distance: ${(_totalDistance / 1000).toStringAsFixed(2)} km');
  }

  Future<void> _initializeFirebase() async {
    try {
      if (!_isFirebaseInitialized) {
        await FirebaseService.initialize();
        _isFirebaseInitialized = true;
      }
    } catch (e) {
      print('Error initializing Firebase in background: $e');
      _isFirebaseInitialized = false;
    }
  }

  Future<void> _loadTripData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? tripDataJson = prefs.getString('trip_data');

      if (tripDataJson != null) {
        final Map<String, dynamic> tripData = json.decode(tripDataJson);

        if (tripData['polylinePoints'] != null) {
          final List<dynamic> points = tripData['polylinePoints'];
          _polylinePoints = points.map((point) => LatLng(point['lat'], point['lng'])).toList();
        }

        double storedDistance = (tripData['totalDistance'] ?? 0.0).toDouble();
        _totalDistance = storedDistance * 1000;

        _currentTripId = tripData['tripId'];
        _employeeId = tripData['employeeId'];
        _employeeName = tripData['employeeName'];
      }
    } catch (e) {
      print('Error loading trip data: $e');
    }
  }

  void _startFirebaseUpdateTimer() {
    _firebaseUpdateTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_isRunning || _polylinePoints.isEmpty || _currentTripId == null) return;

      if (!_isFirebaseInitialized) {
        await _initializeFirebase();
        if (!_isFirebaseInitialized) return;
      }

      final currentLocation = _polylinePoints.last;
      await FirebaseService.sendLiveLocation(
        tripId: _currentTripId!,
        location: currentLocation,
        distanceInKm: _totalDistance / 1000,
        isMoving: _isMoving,
      );
    });
  }

  Future<void> _saveTripData() async {
    if (!_isRunning) return;

    try {
      final prefs = await SharedPreferences.getInstance();

      final Map<String, dynamic> tripData = {
        'polylinePoints': _polylinePoints.map((point) => {'lat': point.latitude, 'lng': point.longitude}).toList(),
        'totalDistance': _totalDistance / 1000,
        'tripId': _currentTripId,
        'employeeId': _employeeId,
        'employeeName': _employeeName,
        'lastUpdate': DateTime.now().toIso8601String(),
      };

      await prefs.setString('trip_data', json.encode(tripData));
      await prefs.setBool('service_running', true);
    } catch (e) {
      print('Error saving trip data: $e');
    }
  }

  void _startLocationTracking() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5, // check every 5m for stop-point logic
      ),
    ).listen((Position position) async {
      if (!_isRunning) return;

      _count++;

      if (position.accuracy != null && position.accuracy! > 50.0) return;

      final currentLatLng = LatLng(position.latitude, position.longitude);
      final double speed = position.speed;

      _updateMovementStatus(speed, currentLatLng);

      if (_isMoving || _polylinePoints.isEmpty) {
        await _processLocationUpdate(currentLatLng, position);
      }

      // Add current position to recent positions
      _recentPositions.add(currentLatLng);
      if (_recentPositions.length > 12) _recentPositions.removeAt(0); // keep last 1 min positions approx

      _lastMovementTime = DateTime.now();
    });

    _movementTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (!_isRunning) {
        timer.cancel();
        return;
      }

      if (_lastMovementTime != null &&
          DateTime.now().difference(_lastMovementTime!) > const Duration(minutes: 2)) {
        _isMoving = false;
        _updateNotification();
      }
    });
  }

void _updateMovementStatus(double speed, LatLng currentLatLng) {
  bool wasMoving = _isMoving;

  // Determine movement status
  if (speed > 1.0) {
    _isMoving = true;
  } else if (_polylinePoints.isNotEmpty) {
    double distanceFromLast = _calculateDistance(
      _polylinePoints.last.latitude,
      _polylinePoints.last.longitude,
      currentLatLng.latitude,
      currentLatLng.longitude,
    );
    _isMoving = distanceFromLast > 10;
  } else {
    _isMoving = false;
  }

  // ----- Flexible Stop-point logic -----
  _recentPositions.add(currentLatLng);
  if (_recentPositions.length > 120) _recentPositions.removeAt(0); // last ~10 min (5s interval)

  if (_stopStartPosition == null) {
    _stopStartPosition = currentLatLng;
    _stopStartTime = DateTime.now();
    _stopAccumulatedDistance = 0.0;
    _stopPointRecorded = false;
  } else {
    // Calculate max distance from stop start position
    double maxDistance = _recentPositions
        .map((p) => _calculateDistance(_stopStartPosition!.latitude, _stopStartPosition!.longitude, p.latitude, p.longitude))
        .reduce(max);

    Duration elapsed = DateTime.now().difference(_stopStartTime!);

    // Record stop if stationary/within 30m for 10+ minutes (cumulative)
    if (!_stopPointRecorded && elapsed.inMinutes >= 3 && maxDistance <= 30) {
      _recordStopPoint(_stopStartPosition!, _stopStartTime!, DateTime.now());
      _stopPointRecorded = true;
      print("📍 Stop point recorded at $_stopStartPosition for ${elapsed.inMinutes} min.");
    }

    // Reset if moved beyond 30m after recording
    if (_stopPointRecorded && maxDistance > 30) {
      _stopStartPosition = currentLatLng;
      _stopStartTime = DateTime.now();
      _stopPointRecorded = false;
      _recentPositions.clear();
      _recentPositions.add(currentLatLng);
    }

    // Reset if moving fast beyond 30m without recording
    if (_isMoving && !_stopPointRecorded && maxDistance > 30) {
      _stopStartPosition = currentLatLng;
      _stopStartTime = DateTime.now();
      _recentPositions.clear();
      _recentPositions.add(currentLatLng);
      _stopAccumulatedDistance = 0.0;
    }
  }
  // ------------------------------------

  if (wasMoving != _isMoving) {
    print('Movement status: ${_isMoving ? 'Moving' : 'Stationary'}');
  }
}






  Future<void> _processLocationUpdate(LatLng currentLatLng, Position position) async {
  if (!_isRunning) return;

  bool shouldAddPoint = false;

  if (_polylinePoints.isEmpty) {
    shouldAddPoint = true;
  } else {
    double distanceFromLast = _calculateDistance(
      _polylinePoints.last.latitude,
      _polylinePoints.last.longitude,
      currentLatLng.latitude,
      currentLatLng.longitude,
    );

    shouldAddPoint = distanceFromLast > 10;
  }

  if (shouldAddPoint) {
    if (_previousPosition != null) {
      final double distance = _calculateDistance(
        _previousPosition!.latitude,
        _previousPosition!.longitude,
        currentLatLng.latitude,
        currentLatLng.longitude,
      );
      _totalDistance += distance;

      // ---- Save every 0.5 km ----
      if ((_totalDistance - _lastSavedDistance) >= 500) { // 500 meters
        _lastSavedDistance = _totalDistance;
        if (_currentTripId != null) {
          await FirebaseService.savePathPoint(
            tripId: _currentTripId!,
            point: currentLatLng,
          );
        }
      }
      // --------------------------
    } else {
      _previousPosition = currentLatLng;
    }

    _polylinePoints.add(currentLatLng);
    _previousPosition = currentLatLng;

    if (_sendPort != null) {
      _sendPort!.send({
        "latitude": position.latitude,
        "longitude": position.longitude,
        "count": _count,
        "polylinePoints": _polylinePoints.map((point) => {'lat': point.latitude, 'lng': point.longitude}).toList(),
        "totalDistance": _totalDistance / 1000,
        "isMoving": _isMoving,
      });
    }

    _updateNotification();
    await _saveTripData();
  }
}


  void _recordStopPoint(LatLng position, DateTime start, DateTime end) {
    final stop = {
      "lat": position.latitude,
      "lng": position.longitude,
      "startTime": start.toIso8601String(),
      "endTime": end.toIso8601String(),
      "durationMinutes": end.difference(start).inMinutes,
    };

    print("📍 Stop recorded: $stop");

    if (_currentTripId != null) {
      FirebaseService.saveStopPoint(
        tripId: _currentTripId!,
        stop: stop,
      );
    }
  }

  void _startStopPointChecker() {
  _stopPointTimer = Timer.periodic(const Duration(seconds: 10), (_) {
    if (!_isRunning || _stopStartPosition == null || _recentPositions.isEmpty) return;

    // Keep recent positions within last ~10min
    if (_recentPositions.length > 120) _recentPositions.removeAt(0);

    // Calculate max distance from stop start position
    double maxDistance = _recentPositions
        .map((p) => _calculateDistance(_stopStartPosition!.latitude, _stopStartPosition!.longitude, p.latitude, p.longitude))
        .reduce(max);

    // If user moved beyond 30m after being stationary, reset stop
    if (_stopPointRecorded && maxDistance > 30) {
      _stopStartPosition = null;
      _stopStartTime = null;
      _stopPointRecorded = false;
      _recentPositions.clear();
    }
  });
}


  void _updateNotification() {
    if (!_isRunning) return;

    FlutterForegroundTask.updateService(
      notificationTitle: _isMoving ? 'Trip in Progress' : 'Trip Paused',
      notificationText: 'Distance: ${(_totalDistance / 1000).toStringAsFixed(2)} km',
    );
  }

  void _sendStatusUpdate() {
    if (_sendPort != null && _isRunning) {
      _sendPort!.send({
        'type': 'status',
        'isRunning': true,
        'totalDistance': _totalDistance / 1000,
      });
    }
  }

  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371000;

    double dLat = _toRadians(lat2 - lat1);
    double dLon = _toRadians(lon2 - lon1);

    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) * cos(_toRadians(lat2)) *
            sin(dLon / 2) * sin(dLon / 2);

    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) {
    return degrees * pi / 180;
  }

  @override
  void onReceiveData(Object data) async {
    if (data is Map<String, dynamic>) {
      if (data['action'] == 'get_status') {
        _sendStatusUpdate();
      } else if (data['action'] == 'clear_data') {
        await _clearData();
      } else if (data['tripId'] != null) {
        _currentTripId = data['tripId'];
        _employeeId = data['employeeId'];
        _employeeName = data['employeeName'];
        await _saveTripData();
      }
    }
  }

  Future<void> _clearData() async {
    _polylinePoints.clear();
    _totalDistance = 0.0;
    _previousPosition = null;
    _isMoving = false;
    _currentTripId = null;
    _employeeId = null;
    _employeeName = null;
    _stopStartPosition = null;
    _stopStartTime = null;
    _stopPointRecorded = false;
    _readyToRecordStop = false;
    _recentPositions.clear();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('trip_data');
      await prefs.setBool('service_running', false);
    } catch (e) {
      print('Error clearing data: $e');
    }

    _updateNotification();
    _sendStatusUpdate();
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {
    if (_isRunning && _polylinePoints.isNotEmpty) {
      _updateNotification();
    }
  }

  @override
  void onDestroy(DateTime timestamp, SendPort? sendPort) async {
    _isRunning = false;
    _positionStream?.cancel();
    _movementTimer?.cancel();
    _firebaseUpdateTimer?.cancel();
    _stopPointTimer?.cancel();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('service_running', false);
    } catch (e) {
      print('Error saving final state: $e');
    }

    print('Task destroyed. Final distance: ${(_totalDistance / 1000).toStringAsFixed(2)} km');
  }

  @override
  void onNotificationButtonPressed(String id) {
    print('Notification button pressed: $id');
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {
    print('Notification dismissed');
  }
}
