"""
Core graph model.

Design choice that matters for correctness (per spec requirement 1):
floor is part of a node's IDENTITY, not just a metadata field you could
accidentally ignore. We enforce this two ways:
  1. Every node's `id` is expected to already be globally unique across
     floors (the floor-graph generator prefixes ids with f{floor}-...).
     merge_floors() asserts this rather than silently trusting it.
  2. Nodes are never looked up, matched, or deduplicated by (x, y) anywhere
     in this package. The ONLY thing that pairs nodes across floors is the
     explicit `connector_group` field (handled in connectors.py), never
     coordinates and never a bare id string.
"""
from __future__ import annotations
from dataclasses import dataclass, field
import json


@dataclass
class Node:
    id: str
    x: float
    y: float
    floor: int
    room: str | None = None
    accessible: bool = True
    type: str = "room"                 # room | junction | stair | elevator | entrance
    connector_group: str | None = None  # set only for stair/elevator nodes

    @staticmethod
    def from_dict(d: dict) -> "Node":
        return Node(
            id=d["id"], x=d["x"], y=d["y"], floor=d["floor"],
            room=d.get("room"), accessible=d.get("accessible", True),
            type=d.get("type", "room"), connector_group=d.get("connector_group"),
        )


@dataclass
class Edge:
    frm: str
    to: str
    cost: float
    accessible: bool = True
    type: str = "walk"                 # walk | connector

    @staticmethod
    def from_dict(d: dict) -> "Edge":
        return Edge(
            frm=d["from"], to=d["to"], cost=d["cost"],
            accessible=d.get("accessible", True), type=d.get("type", "walk"),
        )


@dataclass
class Graph:
    nodes: dict[str, Node] = field(default_factory=dict)
    edges: list[Edge] = field(default_factory=list)
    # adjacency built lazily for the pathfinder
    _adj: dict[str, list[Edge]] | None = field(default=None, repr=False, compare=False)

    def add_node(self, node: Node) -> None:
        if node.id in self.nodes:
            raise ValueError(
                f"Duplicate node id '{node.id}'. Node ids must be globally "
                f"unique across all floors -- two nodes with the same x/y on "
                f"different floors must still have different ids."
            )
        self.nodes[node.id] = node
        self._adj = None  # invalidate cache

    def add_edge(self, edge: Edge) -> None:
        if edge.frm not in self.nodes or edge.to not in self.nodes:
            raise ValueError(f"Edge references unknown node: {edge.frm} -> {edge.to}")
        self.edges.append(edge)
        self._adj = None

    def adjacency(self) -> dict[str, list[Edge]]:
        if self._adj is None:
            adj: dict[str, list[Edge]] = {nid: [] for nid in self.nodes}
            for e in self.edges:
                adj[e.frm].append(e)
            self._adj = adj
        return self._adj


def load_floor(path: str) -> Graph:
    """Load a single floor's graph JSON (schema from the spec, plus the
    optional type/connector_group fields) into a Graph."""
    with open(path) as f:
        data = json.load(f)
    g = Graph()
    for nd in data["nodes"]:
        g.add_node(Node.from_dict(nd))
    for ed in data["edges"]:
        g.add_edge(Edge.from_dict(ed))
    return g


def merge_floors(floor_graphs: list[Graph]) -> Graph:
    """Combine several per-floor graphs into one graph the pathfinder can
    route across directly. This does NOT add any cross-floor edges itself --
    call build_vertical_connectors() afterwards for that. Raises if any node
    id collides across floors (which would indicate ids were not floor-
    qualified, i.e. the exact bug requirement 1 guards against)."""
    combined = Graph()
    for g in floor_graphs:
        for node in g.nodes.values():
            combined.add_node(node)  # raises on id collision
        for edge in g.edges:
            combined.edges.append(edge)
    combined._adj = None
    return combined
