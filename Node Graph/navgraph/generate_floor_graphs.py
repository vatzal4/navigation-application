"""
Builds floor-0.json, floor-1.json, floor-2.json — one nav graph per floor,
matching the schema from the spec:

{
  "nodes": [ { "id": "", "x": 0, "y": 0, "floor": 0, "room": "", "accessible": true } ],
  "edges": [ { "from": "", "to": "", "cost": 0 } ]
}

plus two extra fields used by the multi-floor extension in navgraph/:
  - node.type:            "room" | "junction" | "stair" | "elevator" | "entrance"
  - node.connector_group: shared across floors for stair/elevator nodes only,
                           e.g. "stairs-nw" -- this is what lets the connector
                           builder pair up the right nodes across floors
                           WITHOUT matching on x/y or on the raw node id.

Node ids are floor-prefixed and therefore globally unique (f0-room-top-02,
f1-stairs-nw, ...) -- floor is part of identity, never inferred from x/y.

Room/hall/stair geometry below is the same geometry used to generate the
three floor SVGs earlier in this conversation, so node (x, y) lines up with
the matching shape on the matching SVG.
"""
import json
import math

ROOMS_RECT = {
    "top-01-stair-alcove": (146, 135, 349, 253),
    "top-02": (349, 135, 642, 253),
    "top-03": (642, 135, 794, 253),
    "top-04": (794, 135, 939, 253),
    "top-05-riser": (939, 83, 1073, 253),
    "top-06": (1073, 135, 1232, 253),
    "top-07": (1232, 135, 1422, 253),
    "west-01": (19, 149, 146, 255),
    "west-02": (19, 259, 146, 326),
    "west-03": (19, 332, 146, 613),
    "west-04-alcove": (146, 622, 260, 741),
    "mid-01": (700, 295, 885, 493),
    "mid-02": (700, 499, 885, 593),
    "bottom-01": (384, 634, 706, 753),
    "bottom-02": (714, 634, 950, 753),
    "bottom-03": (1086, 634, 1334, 753),
    "bottom-04": (1334, 634, 1422, 753),
    "east-01": (1433, 221, 1560, 400),
    "east-02": (1433, 400, 1560, 528),
    "east-03": (1433, 528, 1560, 654),
    "hall-west": (366, 298, 652, 586),
    "hall-east": (937, 298, 1348, 590),
}

# stair centers -- same coordinates on every floor, by construction
STAIRS = {
    "stairs-nw": (223, 189),
    "stairs-ne": (1384, 200),
    "stairs-sw": (220, 656),
    "stairs-s":  (1015, 776),
    "stairs-c1": (942, 507),
    "stairs-c2": (1027, 562),
}

# Synthetic/placeholder elevator. The surveyed building (Step 3 of the doc)
# doesn't have a real one yet -- added here only so the accessible-route
# path (requirement 8) has something to route through. Replace with real
# coordinates once the building is surveyed; everything downstream only
# cares that it is a "elevator" node sharing a connector_group across floors.
ELEVATOR = {"elevator-main": (1497, 460)}

# East-west corridor spine running through the open-plan area, repeated
# identically on every floor.
SPINE = [(200, 440), (500, 440), (800, 440), (1100, 440), (1350, 440)]

FLOORS = [
    {"index": 0, "label": "Ground Floor", "has_entrance": True},
    {"index": 1, "label": "First Floor", "has_entrance": False},
    {"index": 2, "label": "Second Floor", "has_entrance": False},
]

STAIR_FLIGHT_COST = 15     # seconds, per floor crossed, one direction
ELEVATOR_BASE_COST = 25    # seconds -- door + ride time, wait time handled separately
ELEVATOR_WAIT_COST = 20    # seconds, average wait

def centroid(box):
    x0, y0, x1, y1 = box
    return (x0 + x1) / 2, (y0 + y1) / 2

def dist(a, b):
    return round(math.hypot(a[0] - b[0], a[1] - b[1]), 1)

def nearest(point, candidates):
    return min(candidates, key=lambda c: dist(point, c[1]))

def build_floor(index, label, has_entrance):
    nodes = []
    edges = []

    def add_node(id_, x, y, room, type_, accessible=True, connector_group=None):
        n = {
            "id": id_, "x": x, "y": y, "floor": index, "room": room,
            "accessible": accessible, "type": type_,
        }
        if connector_group:
            n["connector_group"] = connector_group
        nodes.append(n)
        return n

    def add_edge(a, b, cost, accessible=True, type_="walk"):
        edges.append({"from": a, "to": b, "cost": cost, "accessible": accessible, "type": type_})
        edges.append({"from": b, "to": a, "cost": cost, "accessible": accessible, "type": type_})

    # corridor spine junctions
    spine_ids = []
    for i, (x, y) in enumerate(SPINE, start=1):
        jid = f"f{index}-junction-{i}"
        add_node(jid, x, y, room=None, type_="junction")
        spine_ids.append((jid, (x, y)))
    for a, b in zip(spine_ids, spine_ids[1:]):
        add_edge(a[0], b[0], dist(a[1], b[1]))

    # rooms + halls -> nearest spine junction
    for room_id, box in ROOMS_RECT.items():
        c = centroid(box)
        nid = f"f{index}-room-{room_id}"
        rtype = "room"
        add_node(nid, c[0], c[1], room=room_id, type_=rtype)
        jid, jpt = nearest(c, spine_ids)
        add_edge(nid, jid, dist(c, jpt))

    # stairwells -> nearest spine junction; connector_group used for
    # cross-floor pairing, NOT for intra-floor walking edges
    for sid, (x, y) in STAIRS.items():
        nid = f"f{index}-{sid}"
        add_node(nid, x, y, room=None, type_="stair", accessible=False,
                  connector_group=sid)
        jid, jpt = nearest((x, y), spine_ids)
        add_edge(nid, jid, dist((x, y), jpt))

    # elevator -> nearest spine junction
    for eid, (x, y) in ELEVATOR.items():
        nid = f"f{index}-{eid}"
        add_node(nid, x, y, room=None, type_="elevator", accessible=True,
                  connector_group=eid)
        jid, jpt = nearest((x, y), spine_ids)
        add_edge(nid, jid, dist((x, y), jpt))

    # ground-floor entrance
    if has_entrance:
        ex, ey = 1560, 400
        nid = f"f{index}-node-entrance"
        add_node(nid, ex, ey, room=None, type_="entrance")
        jid, jpt = nearest((ex, ey), spine_ids)
        add_edge(nid, jid, dist((ex, ey), jpt))

    return {"floor": index, "label": label, "nodes": nodes, "edges": edges}

if __name__ == "__main__":
    for f in FLOORS:
        data = build_floor(f["index"], f["label"], f["has_entrance"])
        path = f'/home/claude/navgraph/graph_data/floor-{f["index"]}.json'
        with open(path, "w") as fh:
            json.dump(data, fh, indent=2)
        print(f'wrote {path}: {len(data["nodes"])} nodes, {len(data["edges"])} edges')
