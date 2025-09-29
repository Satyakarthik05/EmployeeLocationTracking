import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:excel/excel.dart' as excel;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cross_file/cross_file.dart';
import 'dart:io';

import 'trip_tracking_screen.dart';
import 'LoginScreen.dart';

class EmployeeManagementScreen extends StatefulWidget {
  const EmployeeManagementScreen({Key? key}) : super(key: key);

  @override
  State<EmployeeManagementScreen> createState() =>
      _EmployeeManagementScreenState();
}

class _EmployeeManagementScreenState extends State<EmployeeManagementScreen> {
  final CollectionReference employeesRef =
      FirebaseFirestore.instance.collection('employees');

  final TextEditingController _searchController = TextEditingController();
  String _searchText = "";

  DateTime? _selectedStartDate;
  DateTime? _selectedEndDate;

  // ======================== REGISTER / EDIT EMPLOYEE =========================
  Future<void> _showEmployeeBottomSheet({DocumentSnapshot? employee}) async {
    final TextEditingController idController =
        TextEditingController(text: employee?['employeeId']);
    final TextEditingController nameController =
        TextEditingController(text: employee?['fullname']);
    final TextEditingController passwordController =
        TextEditingController(text: employee?['password']);

    final isEditing = employee != null;

    await showModalBottomSheet(
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      context: context,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isEditing ? "Edit Employee" : "Register Employee",
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2E5D5D),
              ),
            ),
            const SizedBox(height: 20),
            _buildTextField(controller: idController, label: "Employee ID"),
            const SizedBox(height: 12),
            _buildTextField(controller: nameController, label: "Full Name"),
            const SizedBox(height: 12),
            _buildTextField(
                controller: passwordController,
                label: "Password",
                isPassword: true),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E5D5D),
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                final empId = idController.text.trim();
                final name = nameController.text.trim();
                final password = passwordController.text.trim();

                if (empId.isEmpty || name.isEmpty || password.isEmpty) return;

                if (isEditing) {
                  await employeesRef.doc(employee!.id).update({
                    'employeeId': empId,
                    'fullname': name,
                    'password': password,
                  });
                } else {
                  await employeesRef.add({
                    'employeeId': empId,
                    'fullname': name,
                    'password': password,
                  });
                }

                Navigator.pop(context);
              },
              child: Text(
  isEditing ? "Update" : "Register",
  style: const TextStyle(
    color: Colors.white,   // 👈 set your preferred text color
    fontSize: 16,          // optional: adjust size
    fontWeight: FontWeight.bold, // optional: bold text
  ),
),

            )
          ],
        ),
      ),
    );
  }

  Future<void> _deleteEmployee(String docId) async {
    await employeesRef.doc(docId).delete();
  }

  Widget _buildTextField(
      {required TextEditingController controller,
      required String label,
      bool isPassword = false}) {
    return TextField(
      controller: controller,
      obscureText: isPassword,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ======================== SHOW TRIPS OF EMPLOYEE =========================
  void _showEmployeeTrips(String empId, String name) {
    final DatabaseReference tripsRef =
        FirebaseDatabase.instance.ref().child('trips');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: Column(
              children: [
                Text(
                  "$name's Trips",
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2E5D5D)),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: StreamBuilder(
                    stream: tripsRef.onValue,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }

                      if (snapshot.data?.snapshot.value == null) {
                        return const Center(child: Text("No trips found"));
                      }

                      // Handle different data structures
                      final data = snapshot.data!.snapshot.value;
                      List<Map<String, dynamic>> allTrips = [];

                      if (data is Map) {
                        final tripsMap = Map<String, dynamic>.from(data);
                        allTrips = tripsMap.entries.map((entry) {
                          final tripData = Map<String, dynamic>.from(entry.value);
                          tripData['tripId'] = entry.key; // Add trip ID from key
                          return tripData;
                        }).toList();
                      } else if (data is List) {
                        allTrips = List<Map<String, dynamic>>.from(data);
                      }

                      final empTrips = allTrips.where((trip) => trip['employeeId'] == empId).toList();

                      if (empTrips.isEmpty) {
                        return const Center(
                            child: Text("No trips for this employee"));
                      }

                      // Sort trips by start date (latest first)
                      empTrips.sort((a, b) {
                        final dateA = DateTime.tryParse(a['startTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
                        final dateB = DateTime.tryParse(b['startTime'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
                        return dateB.compareTo(dateA);
                      });

                      return ListView.builder(
                        itemCount: empTrips.length,
                        itemBuilder: (context, index) {
                          final trip = empTrips[index];
                          final startDate = DateTime.tryParse(trip['startTime'] ?? '');
                          final formattedDate = startDate != null
                              ? "${startDate.day}-${startDate.month}-${startDate.year} ${startDate.hour}:${startDate.minute}"
                              : "N/A";

                          final status = trip['status'] ?? 'unknown';
                          final isLive = status == 'in_progress';

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                            child: ListTile(
                              title: Text("Trip ID: ${trip['tripId'] ?? 'N/A'}"),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("Date: $formattedDate"),
                                  Text(
                                      "Status: ${isLive ? 'Live' : 'Ended'} | Distance: ${trip['totalDistance'] ?? 0} km"),
                                ],
                              ),
                              trailing: Icon(
                                isLive
                                    ? Icons.play_circle_fill
                                    : Icons.check_circle,
                                color: isLive ? Colors.green : Colors.grey,
                              ),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => TripTrackingScreen(
                                        tripId: trip['tripId']),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  // ======================== DATE RANGE PICKER =========================
  Future<void> _pickDateRangeUI() async {
    DateTime? startDate = await showDatePicker(
      context: context,
      initialDate: _selectedStartDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );

    if (startDate == null) return;

    DateTime? endDate = await showDatePicker(
      context: context,
      initialDate: _selectedEndDate ?? startDate,
      firstDate: startDate,
      lastDate: DateTime.now(),
    );

    if (endDate != null) {
      setState(() {
        _selectedStartDate = startDate;
        _selectedEndDate = endDate;
      });
    }
  }

  // ======================== FETCH FILTERED TRIPS =========================
  Future<List<Map<String, dynamic>>> _getFilteredTrips(
      String empId, DateTime? startDate, DateTime? endDate) async {
    final tripsRef = FirebaseDatabase.instance.ref().child('trips');
    final snapshot = await tripsRef.get();

    if (!snapshot.exists) return [];

    // Handle different data structures
    final data = snapshot.value;
    List<Map<String, dynamic>> allTrips = [];

    if (data is Map) {
      final tripsMap = Map<String, dynamic>.from(data);
      allTrips = tripsMap.entries.map((entry) {
        final tripData = Map<String, dynamic>.from(entry.value);
        tripData['tripId'] = entry.key; // Add trip ID from key
        return tripData;
      }).toList();
    } else if (data is List) {
      allTrips = List<Map<String, dynamic>>.from(data);
    }

    // Debug: Print raw data
    print("Raw trips data type: ${data.runtimeType}");
    print("Total trips found: ${allTrips.length}");

    List<Map<String, dynamic>> empTrips = allTrips.where((trip) {
      // Check if employeeId matches
      if (trip['employeeId'] != empId) {
        return false;
      }
      
      final tripDateStr = trip['startTime'] ?? '';
      final tripDate = DateTime.tryParse(tripDateStr);
      if (tripDate == null) return false;

      // Normalize dates for comparison (remove time component)
      final normalizedTripDate = DateTime(tripDate.year, tripDate.month, tripDate.day);
      final normalizedStartDate = startDate != null 
          ? DateTime(startDate.year, startDate.month, startDate.day)
          : null;
      final normalizedEndDate = endDate != null
          ? DateTime(endDate.year, endDate.month, endDate.day)
          : null;

      if (normalizedStartDate != null && normalizedTripDate.isBefore(normalizedStartDate)) {
        return false;
      }
      if (normalizedEndDate != null && normalizedTripDate.isAfter(normalizedEndDate)) {
        return false;
      }
      return true;
    }).map((trip) => {
          'tripId': trip['tripId'] ?? 'N/A',
          'date': trip['startTime'] ?? 'N/A',
          'distance': double.tryParse(trip['totalDistance']?.toString() ?? '0') ?? 0.0,
        }).toList();

    // Debug: Print filtered results
    print("Filtered trips for $empId: ${empTrips.length}");
    for (var trip in empTrips) {
      print("Trip: ${trip['tripId']} - ${trip['date']} - ${trip['distance']}km");
    }

    // Sort trips by date
    empTrips.sort((a, b) {
      final dateA = DateTime.tryParse(a['date']) ?? DateTime(0);
      final dateB = DateTime.tryParse(b['date']) ?? DateTime(0);
      return dateA.compareTo(dateB);
    });

    return empTrips;
  }

  // ======================== EXPORT TO EXCEL & SHARE =========================
  Future<void> _exportTripsToExcel({String? specificEmpId}) async {
  if (_selectedStartDate == null || _selectedEndDate == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Please select start and end date first")),
    );
    return;
  }

  // Show loading indicator
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => const Center(child: CircularProgressIndicator()),
  );

  try {
    final employeesSnapshot = await employeesRef.get();
    final employees = employeesSnapshot.docs;

    // Step 1: Collect all trip dates across all employees
    Set<String> allDatesSet = {};
    Map<String, List<Map<String, dynamic>>> employeeTripsMap = {};

    for (var emp in employees) {
      if (specificEmpId != null && emp['employeeId'] != specificEmpId) continue;

      final trips = await _getFilteredTrips(emp['employeeId'], _selectedStartDate, _selectedEndDate);
      if (trips.isEmpty) continue;

      employeeTripsMap[emp['employeeId']] = trips;

      for (var trip in trips) {
        final tripDate = DateTime.tryParse(trip['date']);
        if (tripDate != null) {
          final formattedDate = "${tripDate.day.toString().padLeft(2,'0')}-${tripDate.month.toString().padLeft(2,'0')}-${tripDate.year}";
          allDatesSet.add(formattedDate);
        }
      }
    }

    if (employeeTripsMap.isEmpty) {
      Navigator.pop(context); // Remove loading dialog
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No trip data found for the selected date range")),
      );
      return;
    }

    // Step 2: Sort dates
    List<String> allDates = allDatesSet.toList();
    allDates.sort((a, b) {
      final dateA = DateTime.parse(a.split('-').reversed.join('-'));
      final dateB = DateTime.parse(b.split('-').reversed.join('-'));
      return dateA.compareTo(dateB);
    });

    // Step 3: Create Excel and header
    final excelFile = excel.Excel.createExcel();
    final sheet = excelFile['Trips'];

    List<String> header = ["Employee ID", "Employee Name"] + allDates + ["Total km"];
    sheet.appendRow(header);

    // Step 4: Fill employee rows
    for (var emp in employees) {
      if (!employeeTripsMap.containsKey(emp['employeeId'])) continue;

      final trips = employeeTripsMap[emp['employeeId']]!;
      double totalKm = 0.0;

      Map<String, double> dateDistanceMap = {};
      for (var trip in trips) {
        final tripDate = DateTime.tryParse(trip['date']);
        if (tripDate != null) {
          final formattedDate = "${tripDate.day.toString().padLeft(2,'0')}-${tripDate.month.toString().padLeft(2,'0')}-${tripDate.year}";
          dateDistanceMap[formattedDate] = (dateDistanceMap[formattedDate] ?? 0) + trip['distance'];
          totalKm += trip['distance'];
        }
      }

      List<dynamic> row = [emp['employeeId'], emp['fullname']];
      for (var date in allDates) {
        row.add(dateDistanceMap[date]?.toStringAsFixed(2) ?? "0.00");
      }
      row.add(totalKm.toStringAsFixed(2));

      sheet.appendRow(row);
    }

    // Step 5: Save and share
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = specificEmpId != null
        ? "Employee_${specificEmpId}_Trips_$timestamp.xlsx"
        : "All_Employees_Trips_$timestamp.xlsx";

    final file = File("${directory.path}/$fileName");
    await file.writeAsBytes(excelFile.save()!);

    Navigator.pop(context); // Remove loading dialog

    await Share.shareXFiles([XFile(file.path)],
        text: specificEmpId != null
            ? "Trips for Employee $specificEmpId"
            : "All Employees Trips Report");

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Excel exported successfully!")),
    );
  } catch (e) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Error exporting Excel: $e")),
    );
  }
}

  // ======================== UI =========================
@override
Widget build(BuildContext context) {
  String dateRangeText = (_selectedStartDate != null && _selectedEndDate != null)
      ? "${_selectedStartDate!.day.toString().padLeft(2, '0')}-${_selectedStartDate!.month.toString().padLeft(2, '0')}-${_selectedStartDate!.year} to ${_selectedEndDate!.day.toString().padLeft(2, '0')}-${_selectedEndDate!.month.toString().padLeft(2, '0')}-${_selectedEndDate!.year}"
      : "Select Date Range";

  return Scaffold(
    backgroundColor: const Color(0xFFF5F7F7),
    appBar: AppBar(
      title: const Text(
        "Employee Management",
        style: TextStyle(
          color: Colors.white,   // Title text color
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      backgroundColor: const Color(0xFF2E5D5D),
      centerTitle: true,
      actions: [
        // Logout button
        IconButton(
          icon: const Icon(Icons.logout, color: Colors.white),
          tooltip: 'Logout',
          onPressed: () {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => LoginScreen()),
              (route) => false,
            );
          },
        ),
        // Download button
        IconButton(
          icon: const Icon(Icons.download, color: Colors.green),
          tooltip: "Download & Share All Employees Trips",
          onPressed: _exportTripsToExcel,
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      backgroundColor: const Color(0xFF2E5D5D),
      onPressed: () => _showEmployeeBottomSheet(),
      child: const Icon(Icons.add, color: Colors.white),
    ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              onChanged: (value) =>
                  setState(() => _searchText = value.toLowerCase()),
              decoration: InputDecoration(
                hintText: "Search by name or ID...",
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          // Date Range Selector
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: GestureDetector(
              onTap: _pickDateRangeUI,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, color: Colors.grey),
                    const SizedBox(width: 10),
                    Expanded(child: Text(dateRangeText)),
                    if (_selectedStartDate != null && _selectedEndDate != null)
                      IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          setState(() {
                            _selectedStartDate = null;
                            _selectedEndDate = null;
                          });
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: employeesRef.snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: Text("No employees found"));
                }

                final employees = snapshot.data!.docs.where((emp) {
                  final fullname = emp['fullname'].toString().toLowerCase();
                  final empId = emp['employeeId'].toString().toLowerCase();
                  return fullname.contains(_searchText) ||
                      empId.contains(_searchText);
                }).toList();

                if (employees.isEmpty) {
                  return const Center(
                      child: Text("No employees match your search"));
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: employees.length,
                  itemBuilder: (_, index) {
                    final emp = employees[index];
                    return Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF2E5D5D),
                          child: Text(
                            emp['fullname'][0].toUpperCase(),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(
                          emp['fullname'],
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: Text("ID: ${emp['employeeId']}"),
                        onTap: () {
                          _showEmployeeTrips(emp['employeeId'], emp['fullname']);
                        },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.download, color: Colors.green),
                              tooltip: "Download & Share Employee Trips",
                              onPressed: () {
                                if (_selectedStartDate == null || _selectedEndDate == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("Please select date range first")),
                                  );
                                  return;
                                }
                                _exportTripsToExcel(specificEmpId: emp['employeeId']);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit,
                                  color: Colors.blueAccent),
                              onPressed: () =>
                                  _showEmployeeBottomSheet(employee: emp),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  color: Colors.redAccent),
                              onPressed: () => _deleteEmployee(emp.id),
                            ),
                          ],
                        ),
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