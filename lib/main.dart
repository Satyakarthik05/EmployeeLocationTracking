import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';

import 'screens/employee_tracking_screen.dart';
import 'screens/LoginScreen.dart';
import 'screens/EmployeeManagementScreen.dart';
import 'screens/trip_tracking_screen.dart'; 
import 'screens/EmployeeTripsScreen.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({Key? key}) : super(key: key);

  Future<Widget> _getInitialScreen() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey('user')) {
      // Already logged in → go to EmployeeTrackingScreen
      return WithForegroundTask(child: const EmployeeTrackingScreen());
    } else {
      // Not logged in → show LoginScreen
      return LoginScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _getInitialScreen(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const MaterialApp(
            home: Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        if (snapshot.hasData) {
          return MaterialApp(
            home: snapshot.data!,
            routes: {
              '/login': (context) => LoginScreen(),
              '/home': (context) =>
                  WithForegroundTask(child: const EmployeeTrackingScreen()),
              '/employeeManagement': (context) => EmployeeManagementScreen(),
              '/employeeTrips': (context) => EmployeeTripsScreen(
        employeeId: '', 
        employeeName: '',
  ),
            },
            onGenerateRoute: (settings) {
              // Handle dynamic route for trip tracking
              if (settings.name == '/tripTracking') {
                final args = settings.arguments as Map<String, dynamic>;
                final tripId = args['tripId'] as String;
                return MaterialPageRoute(
                  builder: (_) => TripTrackingScreen(tripId: tripId),
                );
              }
              return null;
            },
            

          );
        }

        return const MaterialApp(
          home: Scaffold(
            body: Center(child: Text("Error loading app")),
          ),
        );
      },
    );
  }
}
