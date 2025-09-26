class TripModel {
  final String tripId;
  final String employeeId;
  final String employeeName;
  final DateTime startTime;
  final double totalDistance; // in kilometers
  final bool isMoving;
  
  TripModel({
    required this.tripId,
    required this.employeeId,
    required this.employeeName,
    required this.startTime,
    this.totalDistance = 0.0,
    this.isMoving = false,
  });
} 