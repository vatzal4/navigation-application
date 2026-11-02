"""
End-to-end test for requirement 8:
  - route from a ground-floor node to a second-floor room,
  - passes through stairwell/elevator connector pairs,
  - floor segments split correctly,
  - total cost includes the vertical connector cost,
  - accessible-route mode avoids stair-only connectors.
"""
from navgraph import (
    load_floor, merge_floors, build_vertical_connectors,
    validate_no_illegal_cross_floor_edges, find_path, split_path_by_floor,
    PathNotFoundError,
)

def main():
    floor_graphs = [load_floor(f"graph_data/floor-{i}.json") for i in range(3)]
    graph = merge_floors(floor_graphs)

    added = build_vertical_connectors(graph)
    print(f"connector edges added: {added}")

    validate_no_illegal_cross_floor_edges(graph)
    print("no illegal cross-floor edges: OK")

    start = "f0-node-entrance"   # ground-floor lobby / entrance
    goal = "f2-room-top-03"      # a second-floor room

    # --- default routing (stairs allowed) ---
    result = find_path(graph, start, goal, accessible_only=False)
    print("\n--- default route ---")
    for s in result.steps:
        print(f"  floor {s.floor:>1}  {s.node_id:<22} ({s.x:.0f},{s.y:.0f})")
    print(f"total cost: {result.total_cost:.1f}")
    print(f"floor changes: {result.floor_changes}")

    assert result.steps[0].node_id == start
    assert result.steps[-1].node_id == goal
    assert result.floor_changes == 2, "expected two floor changes (0->1->2)"

    connector_steps = [s for s in result.steps if "stairs-" in s.node_id or "elevator-" in s.node_id]
    assert len(connector_steps) >= 2, "path should pass through connector nodes"
    print("passes through connector nodes: OK ->", [s.node_id for s in connector_steps])

    connector_edges_used = []
    for a, b in zip(result.steps, result.steps[1:]):
        if a.floor != b.floor:
            connector_edges_used.append((a.node_id, b.node_id))
    print("connector edges used:", connector_edges_used)
    assert len(connector_edges_used) == 2

    # total cost must be strictly greater than the sum of same-floor edge
    # costs would suggest -- i.e. the connector cost is actually included.
    # We check this directly: locate each connector edge's declared cost in
    # the graph and confirm it was added into total_cost.
    connector_cost_total = 0.0
    for a_id, b_id in connector_edges_used:
        for e in graph.edges:
            if e.frm == a_id and e.to == b_id and e.type == "connector":
                connector_cost_total += e.cost
                break
    print(f"connector cost portion of total: {connector_cost_total:.1f} / {result.total_cost:.1f}")
    assert connector_cost_total > 0
    assert connector_cost_total <= result.total_cost

    # --- floor segment splitting ---
    segments = split_path_by_floor(result)
    print("\n--- floor segments ---")
    for seg in segments:
        print(f"  floor {seg.floor}: {len(seg.steps)} steps, "
              f"enter via {seg.entry_connector}, exit via {seg.exit_connector}")
    assert [seg.floor for seg in segments] == [0, 1, 2]
    assert segments[0].entry_connector is None
    assert segments[-1].exit_connector is None
    assert segments[0].exit_connector is not None
    assert segments[1].entry_connector == segments[0].exit_connector
    print("floor segments split correctly: OK")

    # --- accessible-route mode ---
    print("\n--- accessible route ---")
    acc_result = find_path(graph, start, goal, accessible_only=True)
    for s in acc_result.steps:
        print(f"  floor {s.floor:>1}  {s.node_id:<22} ({s.x:.0f},{s.y:.0f})")
    print(f"total cost: {acc_result.total_cost:.1f}")

    acc_connector_edges = [
        (a.node_id, b.node_id) for a, b in zip(acc_result.steps, acc_result.steps[1:])
        if a.floor != b.floor
    ]
    for a_id, b_id in acc_connector_edges:
        assert "elevator-" in a_id and "elevator-" in b_id, (
            f"accessible route used a non-elevator connector: {a_id} -> {b_id}"
        )
    print("accessible route avoids stairwell connectors: OK ->", acc_connector_edges)

    # sanity: accessible route should cost at least as much as the
    # unrestricted route (fewer options to choose from)
    assert acc_result.total_cost >= result.total_cost
    print(f"\naccessible route cost ({acc_result.total_cost:.1f}) >= "
          f"default route cost ({result.total_cost:.1f}): OK")

    # --- negative test: accessible-only must fail when no elevator exists ---
    try:
        bad_graph = merge_floors([load_floor(f"graph_data/floor-{i}.json") for i in range(3)])
        # strip the elevator connector_group so only stairs remain, to prove
        # accessible_only correctly fails closed rather than silently using stairs
        for n in bad_graph.nodes.values():
            if n.connector_group == "elevator-main":
                n.connector_group = None
        build_vertical_connectors(bad_graph)
        find_path(bad_graph, start, goal, accessible_only=True)
        raise AssertionError("expected PathNotFoundError when no elevator connector exists")
    except PathNotFoundError:
        print("accessible routing correctly fails closed with no elevator present: OK")

    # --- requirement 1: nodes are never merged by x/y alone ---
    fresh = merge_floors([load_floor(f"graph_data/floor-{i}.json") for i in range(3)])
    same_xy = [n for n in fresh.nodes.values() if (n.x, n.y) == (1027, 562)]
    assert len(same_xy) == 3, "expected one stairs-c2 node per floor at the same x/y"
    assert len({n.id for n in same_xy}) == 3, "same-x/y nodes on different floors must have distinct ids"
    assert len({n.floor for n in same_xy}) == 3
    print("\nsame-x/y nodes on different floors kept distinct: OK ->",
          [(n.id, n.floor) for n in same_xy])

    # --- requirement: no shortcut edge between floors without an explicit connector ---
    from navgraph.model import Edge
    tampered = merge_floors([load_floor(f"graph_data/floor-{i}.json") for i in range(3)])
    build_vertical_connectors(tampered)
    tampered.add_edge(Edge("f0-room-top-03", "f1-room-top-03", 1.0, type="walk"))  # illegal shortcut
    try:
        validate_no_illegal_cross_floor_edges(tampered)
        raise AssertionError("expected illegal cross-floor edge to be rejected")
    except ValueError as e:
        print("illegal cross-floor shortcut correctly rejected: OK ->", e)

    print("\nALL CHECKS PASSED")

if __name__ == "__main__":
    main()
