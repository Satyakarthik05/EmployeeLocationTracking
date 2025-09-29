import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'employee_tracking_screen.dart';

class LoginScreen extends StatefulWidget {
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool showPassword = false;
  bool rememberMe = false;
  String? errorMessage;
  bool _firebaseReady = false;
  bool _isLoading = false;

  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _initializeFirebase();
  }

  Future<void> _initializeFirebase() async {
    try {
      await Firebase.initializeApp();
      setState(() => _firebaseReady = true);
    } catch (e) {
      setState(() => errorMessage = 'Firebase initialization failed');
      print('Firebase init error: $e');
    }
  }

  Future<void> handleLogin() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      errorMessage = null;
    });
    FocusScope.of(context).unfocus();

    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (!_firebaseReady) {
      setState(() {
        errorMessage = 'Firebase not initialized yet';
        _isLoading = false;
      });
      return;
    }

    if (username.isEmpty || password.isEmpty) {
      setState(() {
        errorMessage = 'Please enter all fields';
        _isLoading = false;
      });
      return;
    }

    if (username == 'admin' && password == 'admin123') {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('admin', '{"username":"admin","role":"admin"}');
      Navigator.pushReplacementNamed(context, '/employeeManagement');
      return;
    }

    try {
      final query = await FirebaseFirestore.instance
          .collection('employees')
          .where('employeeId', isEqualTo: username)
          .where('password', isEqualTo: password)
          .get();

      if (query.docs.isNotEmpty) {
        final emp = query.docs.first.data();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'user',
          '{"username":"$username","role":"employee","employeeId":"${emp['employeeId']}","fullname":"${emp['fullname']}"}',
        );
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => WithForegroundTask(child: const EmployeeTrackingScreen()),
          ),
        );
      } else {
        setState(() {
          errorMessage = 'Invalid Employee ID or Password';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        errorMessage = 'Something went wrong. Try again.';
        _isLoading = false;
      });
      print('Login error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_firebaseReady) {
      return const Scaffold(
        backgroundColor: Color(0xFF2E5D5D),
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF2E5D5D),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Logo
                   Image.asset(
  'lib/assets/download.png',
  height: 80,
  // Remove color property to keep original image colors
  // color: const Color(0xFF2E5D5D), // REMOVE THIS
),

                    const SizedBox(height: 16),
                    const Center(
                      child: Text(
                        'Employee Login',
                        style: TextStyle(
                          color: Color(0xFF2E5D5D),
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Error Message
                    if (errorMessage != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFE6E6),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFF4444), width: 1),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: Color(0xFFFF4444)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                errorMessage!,
                                style: const TextStyle(
                                  color: Color(0xFFFF4444),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 16),
                    _buildTextField(
                      controller: _usernameController,
                      focusNode: _usernameFocus,
                      label: 'Employee ID',
                      icon: Icons.badge_outlined,
                    ),
                    const SizedBox(height: 16),
                    _buildTextField(
                      controller: _passwordController,
                      focusNode: _passwordFocus,
                      label: 'Password',
                      icon: Icons.lock_outlined,
                      isPassword: true,
                    ),
                    const SizedBox(height: 16),

                    // Row(
                    //   mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    //   children: [
                    //     Row(
                    //       children: [
                    //         Checkbox(
                    //           value: rememberMe,
                    //           onChanged: (val) => setState(() => rememberMe = val!),
                    //           activeColor: const Color(0xFF2E5D5D),
                    //         ),
                    //         const Text("Remember me"),
                    //       ],
                    //     ),
                    //     TextButton(
                    //       onPressed: () {},
                    //       child: const Text(
                    //         "Forgot Password?",
                    //         style: TextStyle(color: Color(0xFF2E5D5D)),
                    //       ),
                    //     ),
                    //   ],
                    // ),
                    const SizedBox(height: 16),

                    SizedBox(
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : handleLogin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E5D5D),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: _isLoading
                            ? const CircularProgressIndicator(color: Colors.white)
                            : const Text('LOGIN', style: TextStyle(fontSize: 18,color: Colors.white, // 👈 change text color here
              fontWeight: FontWeight.bold,)),
                      ),
                    ),
                    // const SizedBox(height: 12),
                    // Container(
                    //   padding: const EdgeInsets.all(12),
                    //   decoration: BoxDecoration(
                    //     color: const Color(0xFFFFFFFF),
                    //     borderRadius: BorderRadius.circular(12),
                    //     border: Border.all(color: const Color(0xFF2E5D5D).withOpacity(0.3)),
                    //   ),
                      // child: const Row(
                      //   children: [
                      //     Icon(Icons.info_outline, color: Color(0xFF2E5D5D)),
                      //     SizedBox(width: 8),
                      //     Expanded(
                      //       child: Text(
                      //         "Admin? Use 'admin' / 'admin123'",
                      //         style: TextStyle(fontSize: 12),
                      //       ),
                      //     ),
                      //   ],
                      // ),
                    // ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required IconData icon,
    bool isPassword = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: focusNode.hasFocus ? const Color(0xFF2E5D5D) : Colors.grey.shade300,
          width: focusNode.hasFocus ? 2 : 1,
        ),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        obscureText: isPassword && !showPassword,
        style: const TextStyle(color: Colors.black87),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: focusNode.hasFocus ? const Color(0xFF2E5D5D) : Colors.grey.shade600),
          prefixIcon: Icon(icon, color: focusNode.hasFocus ? const Color(0xFF2E5D5D) : Colors.grey.shade500),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          suffixIcon: isPassword
              ? IconButton(
                  icon: Icon(showPassword ? Icons.visibility_off : Icons.visibility,
                      color: Colors.grey.shade500),
                  onPressed: () => setState(() => showPassword = !showPassword),
                )
              : null,
        ),
        textInputAction: TextInputAction.next,
        onSubmitted: (_) => FocusScope.of(context).nextFocus(),
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }
}
