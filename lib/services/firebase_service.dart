import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';


class FirebaseService {
  static DatabaseReference? _databaseRef;

  // store offline lost segments
  static List<Map<String, dynamic>> _pendingLostSegments = [];
  static bool _isNetworkAvailable = true;

  static Future<void> initialize() async {
    await Firebase.initializeApp();
    _databaseRef = FirebaseDatabase.instance.ref();
  }

  static Future<bool> _checkNetwork() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        _isNetworkAvailable = true;
        return true;
      }
    } catch (_) {
      _isNetworkAvailable = false;
    }
    return false;
  }

  static Future<void> _flushLostData(String tripId) async {
    if (_pendingLostSegments.isEmpty) return;
    if (!await _checkNetwork()) return;

    try {
      for (var segment in _pendingLostSegments) {
        await _databaseRef
            ?.child('trips/$tripId/connectionLost')
            .push()
            .set(segment);
      }
      _pendingLostSegments.clear();
      print("✅ Flushed lost connection data for trip $tripId");
    } catch (e) {
      print("Error flushing lost data: $e");
    }
  }

  static Future<void> sendTripStart({
    required String tripId,
    required String employeeId,
    required String employeeName,
    required LatLng startLocation,
  }) async {
    try {
      final Map<String, dynamic> tripData = {
        'employeeId': employeeId,
        'employeeName': employeeName,
        'tripId': tripId,
        'startTime': DateTime.now().toIso8601String(),
        'startDate': DateTime.now().toString(),
        'day': DateTime.now().day,
        'month': DateTime.now().month,
        'year': DateTime.now().year,
        'startLocation': {
          'latitude': startLocation.latitude,
          'longitude': startLocation.longitude,
        },
        'status': 'in_progress',
        'totalDistance': 0.0,
        'currentLocation': {
          'latitude': startLocation.latitude,
          'longitude': startLocation.longitude,
          'timestamp': DateTime.now().toIso8601String(),
        },
        'isMoving': false,
      };

      await _databaseRef?.child('trips/$tripId').set(tripData);

       await FirebaseFirestore.instance.collection('employeeTrips').add({
      'employeeId': employeeId,
      'tripId': tripId,
      'createdAt': FieldValue.serverTimestamp(),
    });

      print('Trip started data sent to Firebase: $tripId');
    } catch (e) {
      print('Error sending trip start to Firebase: $e');
    }
  }

  static Future<Map<String, dynamic>?> getTripData(String tripId) async {
    try {
      final snapshot = await _databaseRef?.child('trips/$tripId').get();
      if (snapshot?.exists ?? false) {
        return Map<String, dynamic>.from(snapshot!.value as Map);
      }
    } catch (e) {
      print('Error getting trip data: $e');
    }
    return null;
  }

  static Future<void> sendLiveLocation({
    required String tripId,
    required LatLng location,
    required double distanceInKm,
    required bool isMoving,
  }) async {
    try {
      final Map<String, dynamic> updateData = {
        'currentLocation': {
          'latitude': location.latitude,
          'longitude': location.longitude,
          'timestamp': DateTime.now().toIso8601String(),
        },
        'totalDistance': distanceInKm,
        'isMoving': isMoving,
        'lastUpdate': DateTime.now().toIso8601String(),
      };

      if (await _checkNetwork()) {
        // normal live update
        await _databaseRef?.child('trips/$tripId').update(updateData);

        // flush lost segments if any
        await _flushLostData(tripId);
      } else {
        // store offline lost segments
        if (_pendingLostSegments.isEmpty ||
            _pendingLostSegments.last.containsKey("to")) {
          // start a new segment
          _pendingLostSegments.add({
            'from': {
              'latitude': location.latitude,
              'longitude': location.longitude,
              'timestamp': DateTime.now().toIso8601String(),
            }
          });
        } else {
          // update "to" point of last segment
          _pendingLostSegments.last['to'] = {
            'latitude': location.latitude,
            'longitude': location.longitude,
            'timestamp': DateTime.now().toIso8601String(),
          };
        }
        print("🚫 Network lost, stored offline coordinates");
      }
    } catch (e) {
      print('Error sending live location to Firebase: $e');
    }
  }

  static Future<void> sendTripEnd({
    required String tripId,
    required LatLng endLocation,
    required double totalDistanceInKm,
  }) async {
    try {
      final Map<String, dynamic> endData = {
        'endTime': DateTime.now().toIso8601String(),
        'endLocation': {
          'latitude': endLocation.latitude,
          'longitude': endLocation.longitude,
        },
        'totalDistance': totalDistanceInKm,
        'status': 'completed',
      };

      await _databaseRef?.child('trips/$tripId').update(endData);

      print('Trip ended data sent to Firebase: $tripId');
    } catch (e) {
      print('Error sending trip end to Firebase: $e');
    }
  }

  // -------------------- New: Save Point Every 0.5km --------------------
  static Future<void> savePathPoint({
    required String tripId,
    required LatLng point,
  }) async {
    if (!await _checkNetwork()) {
      print("🚫 Network lost, path point not sent yet: $point");
      return;
    }

    try {
      final DatabaseReference pointsRef = _databaseRef!.child('trips/$tripId/points');
      
      final newPointRef = pointsRef.push();
      await newPointRef.set({
        'latitude': point.latitude,
        'longitude': point.longitude,
        'timestamp': ServerValue.timestamp,
      });
      
      print("📍 Path point saved to Firebase (0.5km): ${point.latitude}, ${point.longitude}");
    } catch (e) {
      print("Error saving path point: $e");
    }
  }

  // -------------------- Get Path Points --------------------
  static Future<Map<String, dynamic>?> getPathPoints(String tripId) async {
    try {
      final snapshot = await _databaseRef?.child('trips/$tripId/points').get();
      if (snapshot?.exists ?? false) {
        return Map<String, dynamic>.from(snapshot!.value as Map);
      }
    } catch (e) {
      print('Error getting path points: $e');
    }
    return null;
  }

  // -------------------- Save Stop Point --------------------
  static Future<void> saveStopPoint({
    required String tripId,
    required Map<String, dynamic> stop,
  }) async {
    if (!await _checkNetwork()) {
      print("🚫 Network lost, stop point not sent yet: $stop");
      return;
    }

    try {
      await _databaseRef?.child('trips/$tripId/stopPoints').push().set(stop);
      print("📍 Stop point sent to Firebase: $stop");
    } catch (e) {
      print("Error sending stop point: $e");
    }
  }
}