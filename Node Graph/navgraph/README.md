# Multi-floor indoor navigation graph

Extends the single-floor nav graph (Step 2 of the wayfinding doc) to route
across floors, using the stairwells/elevator as explicit connector edges.

## Files

- `graph_data/floor-0.json`, `floor-1.json`, `floor-2.json` — one nav graph
  per floor, generated from the same room/stair/hall geometry used to build
  the three floor SVGs. Schema: spec's `{nodes, edges}` shape, plus two
  extra node fields:
  - `type`: `"room" | "junction" | "stair" | "elevator" | "entrance"`
  - `connector_group`: set only on stair/elevator nodes, shared across
    floors for the *same physical* stairwell/elevator (e.g. `"stairs-nw"`).
    This — not x/y, not the raw node id — is what the connector builder
    uses to pair nodes across floors.
- `generate_floor_graphs.py` — regenerates the three JSON files above.
  **Note:** this building's survey (per your doc's Step 3) doesn't include
  an elevator yet, so one placeholder `elevator-main` connector is added
  purely so accessible routing has something to route through — swap in
  real coordinates once the building is surveyed.
- `navgraph/` — the package:
  - `model.py` — `Node`, `Edge`, `Graph`, `load_floor()`, `merge_floors()`.
    Node ids are floor-prefixed (`f0-room-top-03`) and `merge_floors()`
    raises on any id collision, so floor is enforced as part of a node's
    identity rather than trusted metadata (requirement 1).
  - `connectors.py` — `build_vertical_connectors()` groups nodes by
    `connector_group`, links adjacent floors only, costs stairs at 15s per
    flight and elevators at a wait + ride cost, and sets `accessible=False`
    on stair connector edges / `accessible=True` on elevator ones.
    `validate_no_illegal_cross_floor_edges()` raises if any edge crosses
    floors without `type="connector"` — the guard against shortcut paths.
  - `pathfinder.py` — plain Dijkstra; connector edges are not special-cased,
    they're just edges with a cost. `accessible_only=True` filters out any
    edge with `accessible=False`. Result includes each step's floor number
    and the number of floor changes.
  - `postprocess.py` — `split_path_by_floor()` cuts one path into
    per-floor segments, each endable/startable on a connector node that
    actually exists on that floor's SVG.
- `test_routing.py` — end-to-end test: ground-floor entrance → a
  second-floor room, both default and accessible-only, plus the two safety
  checks (no x/y-based merging, no illegal cross-floor shortcuts).

## Run it

```bash
cd navgraph
python3 generate_floor_graphs.py   # (already run — graph_data/*.json included)
python3 test_routing.py
```

## Wiring into the app

```python
from navgraph import load_floor, merge_floors, build_vertical_connectors, find_path, split_path_by_floor

graphs = [load_floor(f"graph_data/floor-{i}.json") for i in range(3)]
graph = merge_floors(graphs)
build_vertical_connectors(graph)

result = find_path(graph, "f0-node-entrance", "f2-room-top-03", accessible_only=False)
segments = split_path_by_floor(result)
for seg in segments:
    # draw seg.steps as a polyline onto floor-{seg.floor}.svg,
    # swap the displayed SVG when moving to the next segment
    ...
```

## Known simplifications (flagged, not hidden)

- The corridor "spine" each room connects to is a straight east-west line
  through the open-plan area — a simplification of the real corridor
  topology, good enough to test routing logic, worth refining against the
  actual walkable paths before production use.
- `elevator-main` is a placeholder (see above) — not yet a surveyed
  elevator.
- The two central stairs (`stairs-c1`, `stairs-c2`) are treated as two
  separate single-flight connectors rather than one interlocking double
  stair; adjust `generate_floor_graphs.py` if they should be merged into
  one connector group.
