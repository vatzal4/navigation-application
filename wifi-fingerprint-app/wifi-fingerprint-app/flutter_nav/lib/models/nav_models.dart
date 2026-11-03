// Navigation and positioning models for indoor wayfinding.

class RoomDestination {
  final String roomId;
  final String displayName;
  final int floorNumber;
  final String nodeId;
  final double? x;
  final double? y;

  const RoomDestination({
    required this.roomId,
    required this.displayName,
    required this.floorNumber,
    required this.nodeId,
    this.x,
    this.y,
  });

  factory RoomDestination.fromJson(Map<String, dynamic> json) {
    return RoomDestination(
      roomId: json['room_id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? 'Room',
      floorNumber: (json['floor_number'] as num?)?.toInt() ?? 0,
      nodeId: json['node_id'] as String? ?? '',
      x: (json['x'] as num?)?.toDouble(),
      y: (json['y'] as num?)?.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RoomDestination &&
          runtimeType == other.runtimeType &&
          nodeId == other.nodeId &&
          roomId == other.roomId;

  @override
  int get hashCode => nodeId.hashCode ^ roomId.hashCode;
}

class RouteStep {
  final String nodeId;
  final double x;
  final double y;
  final int floorNumber;
  final String? room;

  const RouteStep({
    required this.nodeId,
    required this.x,
    required this.y,
    required this.floorNumber,
    this.room,
  });

  factory RouteStep.fromJson(Map<String, dynamic> json) {
    return RouteStep(
      nodeId: json['node_id'] as String? ?? json['id'] as String? ?? '',
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      floorNumber: (json['floor_number'] as num?)?.toInt() ??
          (json['floor'] as num?)?.toInt() ??
          0,
      room: json['room'] as String?,
    );
  }
}

class RouteSegment {
  final int floorNumber;
  final List<RouteStep> steps;
  final String? entryConnector;
  final String? exitConnector;

  const RouteSegment({
    required this.floorNumber,
    required this.steps,
    this.entryConnector,
    this.exitConnector,
  });

  factory RouteSegment.fromJson(Map<String, dynamic> json) {
    final rawSteps = (json['nodes'] ?? json['steps']) as List<dynamic>? ?? [];
    return RouteSegment(
      floorNumber: (json['floor_number'] as num?)?.toInt() ??
          (json['floor'] as num?)?.toInt() ??
          0,
      steps: rawSteps
          .map((s) => RouteStep.fromJson(s as Map<String, dynamic>))
          .toList(),
      entryConnector: json['entry_connector'] as String?,
      exitConnector: json['exit_connector'] as String?,
    );
  }
}

class RouteResult {
  final String building;
  final String fromNode;
  final String toNode;
  final bool accessible;
  final double totalLengthMeters;
  final int floorChanges;
  final List<RouteStep> nodes;
  final List<RouteSegment> segments;

  const RouteResult({
    required this.building,
    required this.fromNode,
    required this.toNode,
    required this.accessible,
    required this.totalLengthMeters,
    required this.floorChanges,
    required this.nodes,
    required this.segments,
  });

  factory RouteResult.fromJson(Map<String, dynamic> json) {
    final rawNodes = (json['nodes'] ?? json['steps']) as List<dynamic>? ?? [];
    final rawSegments = json['segments'] as List<dynamic>? ?? [];

    return RouteResult(
      building: json['building'] as String? ?? 'SOS',
      fromNode: json['from_node'] as String? ?? '',
      toNode: json['to_node'] as String? ?? '',
      accessible: json['accessible'] as bool? ?? false,
      totalLengthMeters: (json['total_length_meters'] as num?)?.toDouble() ??
          (json['total_meters'] as num?)?.toDouble() ??
          0.0,
      floorChanges: (json['floor_changes'] as num?)?.toInt() ?? 0,
      nodes: rawNodes
          .map((n) => RouteStep.fromJson(n as Map<String, dynamic>))
          .toList(),
      segments: rawSegments
          .map((s) => RouteSegment.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}

class LocateResult {
  final double x;
  final double y;
  final int floorNumber;
  final dynamic floorId;
  final double confidence;
  final int neighborsUsed;

  const LocateResult({
    required this.x,
    required this.y,
    required this.floorNumber,
    this.floorId,
    required this.confidence,
    required this.neighborsUsed,
  });

  factory LocateResult.fromJson(Map<String, dynamic> json) {
    return LocateResult(
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      floorNumber: (json['floor_number'] as num?)?.toInt() ?? 0,
      floorId: json['floor_id'],
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
      neighborsUsed: (json['neighbors_used'] as num?)?.toInt() ?? 0,
    );
  }
}

class UserLocation {
  final double x;
  final double y;
  final int floorNumber;
  final bool isManual;
  final DateTime timestamp;

  const UserLocation({
    required this.x,
    required this.y,
    required this.floorNumber,
    this.isManual = false,
    required this.timestamp,
  });
}
