import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_scan/wifi_scan.dart';

/// Wraps the wifi_scan plugin.
/// Real WiFi AP scanning only works on Android -- iOS blocks third-party apps
/// from reading raw WiFi scan results, so every method returns safe fallback
/// results on iOS instead of throwing.
class WifiScannerService {
  bool get isScanSupportedPlatform => Platform.isAndroid;

  /// Requests location permission required by Android for WiFi scanning.
  Future<bool> requestPermission() async {
    if (!isScanSupportedPlatform) return true;
    final status = await Permission.location.request();
    return status.isGranted;
  }

  Future<bool> hasPermission() async {
    if (!isScanSupportedPlatform) return false;
    return await Permission.location.isGranted;
  }

  /// Requests a fresh WiFi scan on Android.
  Future<bool> requestFreshScan() async {
    if (!isScanSupportedPlatform) return false;

    try {
      final can = await WiFiScan.instance.canStartScan();
      if (can != CanStartScan.yes) return false;
      return await WiFiScan.instance.startScan();
    } catch (_) {
      return false;
    }
  }

  /// Returns the most recent completed scan results as a list of AP readings.
  /// Empty list on iOS or if scanning fails.
  Future<List<Map<String, dynamic>>> getCurrentReadings() async {
    if (!isScanSupportedPlatform) return [];

    try {
      final can = await WiFiScan.instance.canGetScannedResults();
      if (can != CanGetScannedResults.yes) return [];

      final results = await WiFiScan.instance.getScannedResults();
      return results
          .map((ap) => {
                'bssid': ap.bssid,
                'ssid': ap.ssid.isEmpty ? '(hidden)' : ap.ssid,
                'rssi': ap.level,
              })
          .toList();
    } catch (_) {
      return [];
    }
  }
}
