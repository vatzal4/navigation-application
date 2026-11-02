"""
Dijkstra over the combined multi-floor graph. A connector edge (stairs or
elevator) is just another edge with a cost -- the algorithm itself has no
special-case branch for "this edge changes floors". Floor-awareness is
entirely a property of the data (Node.floor) and is surfaced in the result
for the calling app to use when deciding which SVG to show.
"""
from __future__ import annotations
from dataclasses import dataclass
import heapq
from .model import Graph


class PathNotFoundError(Exception):
    pass


@dataclass
class PathStep:
    node_id: str
    floor: int
    x: float
    y: float
    room: str | None


@dataclass
class PathResult:
    steps: list[PathStep]
    total_cost: float
    floor_changes: int   # number of times the floor differs between consecutive steps


def find_path(graph: Graph, start_id: str, goal_id: str, accessible_only: bool = False) -> PathResult:
    """Shortest path from start_id to goal_id.

    accessible_only=True excludes any edge with accessible=False -- this is
    what removes stairwell connector edges (and any other non-accessible
    edge, e.g. a step-only shortcut) from consideration, so the route only
    uses elevators/ramps to change floors. If no accessible path exists,
    PathNotFoundError is raised rather than silently falling back to stairs.
    """
    if start_id not in graph.nodes:
        raise ValueError(f"Unknown start node '{start_id}'")
    if goal_id not in graph.nodes:
        raise ValueError(f"Unknown goal node '{goal_id}'")

    adj = graph.adjacency()
    dist = {start_id: 0.0}
    prev: dict[str, str] = {}
    visited: set[str] = set()
    pq = [(0.0, start_id)]

    while pq:
        d, u = heapq.heappop(pq)
        if u in visited:
            continue
        visited.add(u)
        if u == goal_id:
            break
        for edge in adj[u]:
            if accessible_only and not edge.accessible:
                continue
            v = edge.to
            nd = d + edge.cost
            if nd < dist.get(v, float("inf")):
                dist[v] = nd
                prev[v] = u
                heapq.heappush(pq, (nd, v))

    if goal_id not in dist:
        mode = "accessible " if accessible_only else ""
        raise PathNotFoundError(
            f"No {mode}route found from '{start_id}' to '{goal_id}'."
        )

    # reconstruct
    node_ids = [goal_id]
    while node_ids[-1] != start_id:
        node_ids.append(prev[node_ids[-1]])
    node_ids.reverse()

    steps = []
    for nid in node_ids:
        n = graph.nodes[nid]
        steps.append(PathStep(node_id=n.id, floor=n.floor, x=n.x, y=n.y, room=n.room))

    floor_changes = sum(
        1 for a, b in zip(steps, steps[1:]) if a.floor != b.floor
    )

    return PathResult(steps=steps, total_cost=dist[goal_id], floor_changes=floor_changes)
