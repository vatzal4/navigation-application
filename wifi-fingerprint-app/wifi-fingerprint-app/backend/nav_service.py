"""
Navigation service for multi-floor indoor routing.
Loads floor graph JSON files, builds cross-floor vertical connectors,
and provides routing, room search, and nearest-node snapping.
"""
from __future__ import annotations
import math
import os
from typing import Any, Dict, List, Optional, Tuple

from navgraph import (
    load_floor,
    merge_floors,
    build_vertical_connectors,
    validate_no_illegal_cross_floor_edges,
    find_path,
    split_path_by_floor,
    PathNotFoundError,
)
from navgraph.model import Graph, Node

SVG_UNITS_PER_METER = 18.7
METERS_PER_FLOOR_FLIGHT = 3.5

_script_dir = os.path.dirname(os.path.abspath(__file__))
_graph_data_dir = os.path.join(_script_dir, "graph_data")

# In-memory graph cache: building -> Graph
_graphs: Dict[str, Graph] = {}


def get_building_graph(building: str = "SOS") -> Graph:
    """Loads and caches the multi-floor graph for a building."""
    b_key = building.strip().upper()
    if b_key in _graphs:
        return _graphs[b_key]

    if b_key != "SOS":
        raise ValueError(f"No navigation graph available for building '{building}'")

    floor_files = [
        os.path.join(_graph_data_dir, f"floor-{i}.json")
        for i in range(3)
    ]
    for fp in floor_files:
        if not os.path.exists(fp):
            raise FileNotFoundError(f"Graph file missing: {fp}")

    floor_graphs = [load_floor(fp) for fp in floor_files]
    merged = merge_floors(floor_graphs)
    build_vertical_connectors(merged)
    validate_no_illegal_cross_floor_edges(merged)

    _graphs[b_key] = merged
    return merged


def get_rooms_list(building: str = "SOS") -> List[Dict[str, Any]]:
    """
    Returns list of destinations:
    [{"room_id": str, "display_name": str, "floor_number": int, "node_id": str}]
    """
    graph = get_building_graph(building)
    destinations: List[Dict[str, Any]] = []

    for node in graph.nodes.values():
        if node.room:
            clean_name = node.room.replace("-", " ").title()
            destinations.append({
                "room_id": node.room,
                "display_name": f"{clean_name} (Floor {node.floor})",
                "floor_number": node.floor,
                "node_id": node.id,
                "x": node.x,
                "y": node.y,
            })
        elif node.type == "entrance":
            destinations.append({
                "room_id": "entrance",
                "display_name": f"Main Entrance (Floor {node.floor})",
                "floor_number": node.floor,
                "node_id": node.id,
                "x": node.x,
                "y": node.y,
            })

    # Sort destinations predictably by floor then display_name
    destinations.sort(key=lambda d: (d["floor_number"], d["display_name"]))
    return destinations


def snap_to_nearest_node(graph: Graph, x: float, y: float, floor_number: int) -> Node:
    """Finds the nearest graph node on the specified floor."""
    candidates = [n for n in graph.nodes.values() if n.floor == floor_number]
    if not candidates:
        raise ValueError(f"No graph nodes found on floor {floor_number}")

    return min(candidates, key=lambda n: math.hypot(n.x - x, n.y - y))


class NodeNotFoundError(KeyError):
    pass


def resolve_node_id(graph: Graph, identifier: str, preferred_floor: Optional[int] = None) -> str:
    """
    Resolves a node ID or room ID string to a valid node ID in the graph.
    Returns the node ID, or raises NodeNotFoundError if not found.
    """
    if identifier in graph.nodes:
        return identifier

    # Check if identifier matches node.room
    matching_nodes = [n for n in graph.nodes.values() if n.room == identifier]
    if not matching_nodes:
        # Check case-insensitive
        matching_nodes = [
            n for n in graph.nodes.values()
            if n.room and n.room.lower() == identifier.lower()
        ]

    if preferred_floor is not None:
        floor_matches = [n for n in matching_nodes if n.floor == preferred_floor]
        if floor_matches:
            return floor_matches[0].id

    if matching_nodes:
        return matching_nodes[0].id

    raise NodeNotFoundError(f"Unknown node or room '{identifier}'")


def compute_route(
    building: str = "SOS",
    from_node: Optional[str] = None,
    from_pos: Optional[Dict[str, Any]] = None,
    to_node: Optional[str] = None,
    accessible: bool = False,
) -> Dict[str, Any]:
    """
    Computes shortest path between start and destination.
    Returns ordered nodes, segments, total length in meters, floor changes.
    """
    graph = get_building_graph(building)

    # Resolve start node
    start_id: str
    if from_pos is not None:
        try:
            fx = float(from_pos["x"])
            fy = float(from_pos["y"])
            ffloor = int(from_pos.get("floor_number", from_pos.get("floor", 0)))
        except (KeyError, ValueError, TypeError) as e:
            raise ValueError(f"Invalid from position: {e}")
        nearest_node = snap_to_nearest_node(graph, fx, fy, ffloor)
        start_id = nearest_node.id
    elif from_node is not None:
        start_id = resolve_node_id(graph, from_node)
    else:
        raise ValueError("Must provide either 'from_node' or 'from' position {x, y, floor_number}")

    # Resolve destination node
    if not to_node:
        raise ValueError("Destination 'to_node' (or room id) is required")

    start_floor = graph.nodes[start_id].floor
    goal_id = resolve_node_id(graph, to_node, preferred_floor=start_floor)

    # Run Dijkstra pathfinder
    path_res = find_path(graph, start_id, goal_id, accessible_only=accessible)
    floor_segments = split_path_by_floor(path_res)

    # Calculate total walking distance in meters (18.7 SVG units = 1 m)
    walk_svg_units = 0.0
    for a, b in zip(path_res.steps, path_res.steps[1:]):
        if a.floor == b.floor:
            walk_svg_units += math.hypot(b.x - a.x, b.y - a.y)

    vertical_meters = path_res.floor_changes * METERS_PER_FLOOR_FLIGHT
    total_meters = round((walk_svg_units / SVG_UNITS_PER_METER) + vertical_meters, 1)

    # Format nodes
    ordered_nodes = [
        {
            "node_id": s.node_id,
            "id": s.node_id,
            "x": s.x,
            "y": s.y,
            "floor_number": s.floor,
            "floor": s.floor,
            "room": s.room,
        }
        for s in path_res.steps
    ]

    # Format segments
    segments = []
    for seg in floor_segments:
        seg_nodes = [
            {
                "node_id": s.node_id,
                "id": s.node_id,
                "x": s.x,
                "y": s.y,
                "floor_number": s.floor,
                "floor": s.floor,
                "room": s.room,
            }
            for s in seg.steps
        ]
        segments.append({
            "floor_number": seg.floor,
            "floor": seg.floor,
            "nodes": seg_nodes,
            "steps": seg_nodes,
            "entry_connector": seg.entry_connector,
            "exit_connector": seg.exit_connector,
        })

    return {
        "building": building.upper(),
        "from_node": start_id,
        "to_node": goal_id,
        "accessible": accessible,
        "nodes": ordered_nodes,
        "steps": ordered_nodes,
        "segments": segments,
        "total_length_meters": total_meters,
        "total_meters": total_meters,
        "length_meters": total_meters,
        "floor_changes": path_res.floor_changes,
        "total_cost": round(path_res.total_cost, 2),
    }
