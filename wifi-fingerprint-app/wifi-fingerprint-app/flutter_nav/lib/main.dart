import 'package:flutter/material.dart';
import 'screens/navigation_screen.dart';

/// ============================================================================
/// BACKEND URL CONFIGURATION
/// ============================================================================
/// Change this constant to your laptop's current Wi-Fi IP address and port.
/// - For a physical Android phone on the same Wi-Fi: "http://YOUR_LAPTOP_IP:5050" (e.g. "http://10.205.28.137:5050")
/// - For the Android Emulator: "http://10.0.2.2:5050"
/// - With ADB reverse proxy (adb reverse tcp:5050 tcp:5050): "http://127.0.0.1:5050"
const String backendUrl = "http://10.205.28.137:5050";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NavApp());
}

class NavApp extends StatelessWidget {
  const NavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SOS Indoor Navigation',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF2563EB),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
      ),
      home: const NavigationScreen(backendUrl: backendUrl),
    );
  }
}
