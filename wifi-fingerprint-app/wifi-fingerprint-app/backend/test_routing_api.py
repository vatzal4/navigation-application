"""
Pytest tests for navigation and routing API:
  - same-floor route
  - route across floors via a stairwell
  - unknown node returning 404
  - accessible option avoiding stairs
  - snapping nearest node from {x, y, floor_number}
  - GET /api/rooms destination lookup
  - POST /api/locate with optional floor_number filter
"""
import pytest
from app import app
import nav_service


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


def test_same_floor_route(client):
    """Routing between two nodes on the same floor returns single segment and 200 OK."""
    payload = {
        "building": "SOS",
        "from_node": "f0-room-top-02",
        "to_node": "f0-room-top-03",
        "accessible": False,
    }
    resp = client.post("/api/route", json=payload)
    assert resp.status_code == 200
    data = resp.get_json()

    assert data["building"] == "SOS"
    assert data["from_node"] == "f0-room-top-02"
    assert data["to_node"] == "f0-room-top-03"
    assert data["floor_changes"] == 0
    assert data["total_length_meters"] > 0

    assert len(data["segments"]) == 1
    seg0 = data["segments"][0]
    assert seg0["floor_number"] == 0
    assert seg0["entry_connector"] is None
    assert seg0["exit_connector"] is None
    assert len(seg0["nodes"]) >= 2
    assert seg0["nodes"][0]["node_id"] == "f0-room-top-02"
    assert seg0["nodes"][-1]["node_id"] == "f0-room-top-03"


def test_cross_floor_route_via_stairwell(client):
    """Routing across floors via a stairwell links floors and returns per-floor segments."""
    payload = {
        "building": "SOS",
        "from_node": "f0-node-entrance",
        "to_node": "f2-room-top-03",
        "accessible": False,
    }
    resp = client.post("/api/route", json=payload)
    assert resp.status_code == 200
    data = resp.get_json()

    assert data["floor_changes"] == 2
    assert len(data["segments"]) == 3
    assert [s["floor_number"] for s in data["segments"]] == [0, 1, 2]

    # Verify stair connector nodes are used in the route
    all_node_ids = [n["node_id"] for n in data["nodes"]]
    assert any("stairs-" in nid for nid in all_node_ids), "Route should traverse stair connector"

    # Segment connectors check
    assert data["segments"][0]["entry_connector"] is None
    assert data["segments"][0]["exit_connector"] is not None
    assert data["segments"][1]["entry_connector"] == data["segments"][0]["exit_connector"]
    assert data["segments"][2]["entry_connector"] == data["segments"][1]["exit_connector"]
    assert data["segments"][2]["exit_connector"] is None


def test_unknown_node_returns_404(client):
    """Routing with an unknown start or destination node returns 404."""
    # Unknown destination node
    resp = client.post("/api/route", json={
        "building": "SOS",
        "from_node": "f0-node-entrance",
        "to_node": "nonexistent-room-999",
    })
    assert resp.status_code == 404
    data = resp.get_json()
    assert "error" in data

    # Unknown start node
    resp2 = client.post("/api/route", json={
        "building": "SOS",
        "from_node": "unknown-node-xyz",
        "to_node": "f0-room-top-03",
    })
    assert resp2.status_code == 404


def test_accessible_route_avoids_stairs(client):
    """Accessible route mode avoids stairs and uses elevator connectors."""
    payload = {
        "building": "SOS",
        "from_node": "f0-node-entrance",
        "to_node": "f2-room-top-03",
        "accessible": True,
    }
    resp = client.post("/api/route", json=payload)
    assert resp.status_code == 200
    data = resp.get_json()

    # In accessible mode, cross-floor connectors must be elevator only
    for seg in data["segments"]:
        if seg["exit_connector"]:
            assert "elevator" in seg["exit_connector"], f"Expected elevator connector, got {seg['exit_connector']}"


def test_route_from_position_snaps_nearest_node(client):
    """Providing 'from' with coordinates {x, y, floor_number} snaps to nearest node."""
    payload = {
        "building": "SOS",
        "from": {"x": 1555.0, "y": 395.0, "floor_number": 0},
        "to_node": "f0-room-top-02",
    }
    resp = client.post("/api/route", json=payload)
    assert resp.status_code == 200
    data = resp.get_json()
    # (1555, 395) is closest to f0-node-entrance (1560, 400)
    assert data["from_node"] == "f0-node-entrance"
    assert data["segments"][0]["floor_number"] == 0


def test_get_rooms_list(client):
    """GET /api/rooms returns a list of destinations for search."""
    resp = client.get("/api/rooms?building=SOS")
    assert resp.status_code == 200
    rooms = resp.get_json()
    assert isinstance(rooms, list)
    assert len(rooms) > 0

    # Verify schema of rooms items
    for item in rooms:
        assert "room_id" in item
        assert "display_name" in item
        assert "floor_number" in item
        assert "node_id" in item


def test_locate_with_floor_number_filter():
    """POST /api/locate respects floor_number constraint when provided."""
    import app as backend_app

    mock_fingerprints = [
        {
            "id": "fp_0_1",
            "floor_id": 10,
            "floor_number": 0,
            "x": 100.0,
            "y": 100.0,
            "readings": {"aa:bb:cc:dd:ee:01": -50.0},
        },
        {
            "id": "fp_1_1",
            "floor_id": 11,
            "floor_number": 1,
            "x": 200.0,
            "y": 200.0,
            "readings": {"aa:bb:cc:dd:ee:01": -45.0},  # Stronger RSSI on floor 1
        },
    ]

    # Pre-populate backend cache
    backend_app._fingerprints_cache["sos"] = {
        "timestamp": 9999999999.0,
        "fingerprints": mock_fingerprints,
    }

    test_client = backend_app.app.test_client()

    # 1. Without floor_number: floor 1 wins due to stronger RSSI
    res_unconstrained = test_client.post("/api/locate", json={
        "building": "SOS",
        "readings": [{"bssid": "aa:bb:cc:dd:ee:01", "ssid": "Student", "rssi": -46}],
    })
    assert res_unconstrained.status_code == 200
    assert res_unconstrained.get_json()["floor_number"] == 1

    # 2. With floor_number=0: forces candidates to floor 0 only
    res_constrained = test_client.post("/api/locate", json={
        "building": "SOS",
        "floor_number": 0,
        "readings": [{"bssid": "aa:bb:cc:dd:ee:01", "ssid": "Student", "rssi": -46}],
    })
    assert res_constrained.status_code == 200
    assert res_constrained.get_json()["floor_number"] == 0
    assert res_constrained.get_json()["x"] == 100.0
