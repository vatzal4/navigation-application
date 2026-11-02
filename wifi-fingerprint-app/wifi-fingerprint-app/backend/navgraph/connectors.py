"""
Vertical connectors: pairs stairwell/elevator nodes that share a
`connector_group` across floors (e.g. every node with connector_group
"stairs-nw") and adds edges between adjacent floors only.

Matching is done ONLY via connector_group -- never via x/y, never via a bare
id string match -- so this works even if two unrelated nodes happen to share
coordinates, and even if node ids differ in format between floors.
"""
from __future__ import annotations
from collections import defaultdict
from .model import Graph, Edge

STAIR_COST_PER_FLIGHT = 15      # seconds, one flight = one floor crossed
ELEVATOR_BASE_COST = 25         # seconds, ride + doors, one floor crossed
ELEVATOR_WAIT_COST = 20         # seconds, flat, added once per elevator trip


def _connector_cost(node_type: str, floor_gap: int) -> float:
    if node_type == "elevator":
        return ELEVATOR_WAIT_COST + ELEVATOR_BASE_COST * floor_gap
    # stairs (default for any non-elevator connector type)
    return STAIR_COST_PER_FLIGHT * floor_gap


def build_vertical_connectors(graph: Graph, adjacent_floors_only: bool = True) -> int:
    """Mutates `graph` in place, adding connector edges. Returns the number
    of connector edges added (counting both directions).

    adjacent_floors_only=True (default) only links floor N to floor N+1 for
    a given connector_group, matching how real stairs/elevators work --
    floor 0 cannot connect directly to floor 2 without passing floor 1, even
    if a group happens to have nodes on floors 0 and 2 only (e.g. a stair
    that skips a mezzanine isn't modeled here; use elevators for that).
    """
    groups: dict[str, list] = defaultdict(list)
    for node in graph.nodes.values():
        if node.connector_group:
            groups[node.connector_group].append(node)

    added = 0
    for group_name, members in groups.items():
        if len(members) < 2:
            continue  # connector only exists on one floor -- nothing to link
        members.sort(key=lambda n: n.floor)
        types = {m.type for m in members}
        if len(types) > 1:
            raise ValueError(
                f"connector_group '{group_name}' mixes node types {types} -- "
                f"a stairwell and an elevator must not share a connector_group."
            )
        node_type = members[0].type
        is_accessible = node_type == "elevator"  # stairs: accessible=False,
                                                   # elevator: accessible=True

        pairs = (
            zip(members, members[1:]) if adjacent_floors_only
            else ((a, b) for i, a in enumerate(members) for b in members[i + 1:])
        )
        for a, b in pairs:
            if adjacent_floors_only and b.floor - a.floor != 1:
                continue
            floor_gap = abs(b.floor - a.floor)
            cost = _connector_cost(node_type, floor_gap)
            graph.add_edge(Edge(a.id, b.id, cost, accessible=is_accessible, type="connector"))
            graph.add_edge(Edge(b.id, a.id, cost, accessible=is_accessible, type="connector"))
            added += 2
    graph._adj = None
    return added


def validate_no_illegal_cross_floor_edges(graph: Graph) -> None:
    """Raises if any edge crosses floors without being an explicit
    type='connector' edge. This is the guard against 'shortcut' paths that
    skip the stairwell/elevator -- call this after merging floors and
    building connectors, before handing the graph to the pathfinder."""
    for e in graph.edges:
        a, b = graph.nodes[e.frm], graph.nodes[e.to]
        if a.floor != b.floor and e.type != "connector":
            raise ValueError(
                f"Illegal cross-floor edge {e.frm} (floor {a.floor}) -> "
                f"{e.to} (floor {b.floor}) is not type='connector'. "
                f"Cross-floor travel must go through an explicit vertical "
                f"connector edge."
            )
