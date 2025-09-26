import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'trip_tracking_screen.dart'; // Your existing trip tracking screen
import 'package:intl/intl.dart'; // For formatting date/time nicely

class EmployeeTripsScreen extends StatefulWidget {
  final String employeeId;
  final String employeeName;

  const EmployeeTripsScreen({
    Key? key,
    required this.employeeId,
    required this.employeeName,
  }) : super(key: key);

  @override
  State<EmployeeTripsScreen> createState() => _EmployeeTripsScreenState();
}

class _EmployeeTripsScreenState extends State<EmployeeTripsScreen> {
  late DatabaseReference tripsRef;

  @override
  void initState() {
    super.initState();
    tripsRef = FirebaseDatabase.instance.ref().child('trips');
  }

  String formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('dd-MM-yyyy HH:mm').format(date);
    } catch (e) {
      return "N/A";
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("My Trips"),
        backgroundColor: const Color(0xFF2E5D5D),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Employee info at the top
          Container(
            width: double.infinity,
            color: const Color(0xFFE0F7FA),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Name: ${widget.employeeName}",
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  "ID: ${widget.employeeId}",
                  style: const TextStyle(fontSize: 16, color: Colors.black54),
                ),
              ],
            ),
          ),

          // Trip list
          Expanded(
            child: StreamBuilder<DatabaseEvent>(
              stream: tripsRef.onValue,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
                  return const Center(child: Text("No trips found"));
                }

                // Convert snapshot to Map safely
                final tripsData = Map<String, dynamic>.from(
                  (snapshot.data!.snapshot.value as Map).map(
                    (key, value) => MapEntry(key.toString(), value),
                  ),
                );

                final empTrips = tripsData.entries
                    .where((entry) => entry.value['employeeId'] == widget.employeeId)
                    .toList();

                if (empTrips.isEmpty) {
                  return const Center(child: Text("No trips for this employee"));
                }

                // Sort by start time descending
                empTrips.sort((a, b) {
                  final dateA = DateTime.tryParse(a.value['startTime'] ?? '') ??
                      DateTime.fromMillisecondsSinceEpoch(0);
                  final dateB = DateTime.tryParse(b.value['startTime'] ?? '') ??
                      DateTime.fromMillisecondsSinceEpoch(0);
                  return dateB.compareTo(dateA);
                });

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: empTrips.length,
                  itemBuilder: (context, index) {
                    final trip = empTrips[index].value;
                    final formattedDate = formatDate(trip['startTime'] ?? '');
                    final status = trip['status'] ?? 'unknown';
                    final isLive = status == 'in_progress';
                    final distance = trip['totalDistance']?.toString() ?? 'N/A';

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 3,
                      child: ListTile(
                        title: Text("Trip ID: ${trip['tripId'] ?? 'N/A'}"),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Date: $formattedDate"),
                            Text(
                                "Status: ${isLive ? 'Live' : 'Ended'} | Distance: $distance km"),
                          ],
                        ),
                        trailing: Icon(
                          isLive ? Icons.play_circle_fill : Icons.check_circle,
                          color: isLive ? Colors.green : Colors.grey,
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  TripTrackingScreen(tripId: trip['tripId']),
                            ),
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
