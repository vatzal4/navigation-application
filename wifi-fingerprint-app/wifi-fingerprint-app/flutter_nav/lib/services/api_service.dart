import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/nav_models.dart';

class ApiResponse<T> {
  final bool success;
  final T? data;
  final String? errorMessage;
  final int? statusCode;

  const ApiResponse({
    required this.success,
    this.data,
    this.errorMessage,
    this.statusCode,
  });
}

class NavigationApiService {
  final String baseUrl;

  NavigationApiService({required this.baseUrl});

  /// Check whether the Flask backend is reachable.
  Future<bool> checkHealth() async {
    try {
      final uri = Uri.parse('$baseUrl/health');
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Fetch list of searchable room destinations from the navigation graph metadata.
  Future<ApiResponse<List<RoomDestination>>> getRooms({String building = "SOS"}) async {
    try {
      final uri = Uri.parse('$baseUrl/api/rooms?building=$building');
      final res = await http.get(uri).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List<dynamic>;
        final rooms = list
            .map((item) => RoomDestination.fromJson(item as Map<String, dynamic>))
            .toList();
        return ApiResponse(success: true, data: rooms, statusCode: 200);
      } else {
        return ApiResponse(
          success: false,
          statusCode: res.statusCode,
          errorMessage: 'Failed to load rooms: ${res.statusCode}',
        );
      }
    } on SocketException catch (e) {
      return ApiResponse(
        success: false,
        errorMessage: 'Backend unreachable ($baseUrl). Check your IP and network connection: ${e.message}',
      );
    } on TimeoutException {
      return ApiResponse(
        success: false,
        errorMessage: 'Connection timed out connecting to backend ($baseUrl).',
      );
    } catch (e) {
      return ApiResponse(
        success: false,
        errorMessage: 'Error loading rooms: $e',
      );
    }
  }

  /// Sends averaged WiFi scan readings to estimate location via k-NN.
  /// When floorNumber is provided, candidates are restricted to that floor.
  Future<ApiResponse<LocateResult>> locateUser({
    required String building,
    int? floorNumber,
    required List<Map<String, dynamic>> readings,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/locate');
      final payload = {
        'building': building,
        if (floorNumber != null) 'floor_number': floorNumber,
        'readings': readings,
      };

      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        return ApiResponse(
          success: true,
          data: LocateResult.fromJson(json),
          statusCode: 200,
        );
      } else if (res.statusCode == 422) {
        final body = jsonDecode(res.body);
        final msg = body is Map ? body['error'] ?? 'No Student APs found' : 'Unprocessable';
        return ApiResponse(
          success: false,
          statusCode: 422,
          errorMessage: msg.toString(),
        );
      } else {
        return ApiResponse(
          success: false,
          statusCode: res.statusCode,
          errorMessage: 'Server returned ${res.statusCode}: ${res.body}',
        );
      }
    } on SocketException catch (e) {
      return ApiResponse(
        success: false,
        errorMessage: 'Backend unreachable ($baseUrl). Ensure phone and laptop are on same Wi-Fi: ${e.message}',
      );
    } on TimeoutException {
      return ApiResponse(
        success: false,
        errorMessage: 'Locate request timed out.',
      );
    } catch (e) {
      return ApiResponse(
        success: false,
        errorMessage: 'Locate error: $e',
      );
    }
  }

  /// Calculates Dijkstra multi-floor route from start node/position to destination room.
  Future<ApiResponse<RouteResult>> getRoute({
    required String building,
    String? fromNode,
    Map<String, dynamic>? fromPos,
    required String toNode,
    bool accessible = false,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/route');
      final payload = {
        'building': building,
        if (fromNode != null) 'from_node': fromNode,
        if (fromPos != null) 'from': fromPos,
        'to_node': toNode,
        'accessible': accessible,
      };

      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        return ApiResponse(
          success: true,
          data: RouteResult.fromJson(json),
          statusCode: 200,
        );
      } else {
        final body = jsonDecode(res.body);
        final msg = body is Map ? body['error'] ?? 'Route error' : 'Route error';
        return ApiResponse(
          success: false,
          statusCode: res.statusCode,
          errorMessage: msg.toString(),
        );
      }
    } on SocketException catch (e) {
      return ApiResponse(
        success: false,
        errorMessage: 'Backend unreachable ($baseUrl): ${e.message}',
      );
    } on TimeoutException {
      return ApiResponse(
        success: false,
        errorMessage: 'Route request timed out.',
      );
    } catch (e) {
      return ApiResponse(
        success: false,
        errorMessage: 'Route error: $e',
      );
    }
  }
}
