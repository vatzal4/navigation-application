# Campus Navigation Application

An indoor navigation and wayfinding system for college campuses utilizing SVG floor plans, WiFi fingerprinting, and graph-based shortest path routing.

---

## 🏛️ Project Architecture

```
navigation-application/
├── wifi-fingerprint-app/
│   └── wifi-fingerprint-app/
│       ├── flutter_nav/       # Flutter Turn-by-Turn Navigation App
│       ├── flutter_survey/    # Flutter WiFi Survey & AP Data Collection App
│       ├── backend/           # Flask REST API, WiFi Locator, & MongoDB Layer
│       ├── SOS SVG/           # School of Science floor plan vector maps
│       ├── SOT SVG/           # School of Technology floor plan vector maps
│       └── android/           # Native Android scanner reference snippets
├── Node Graph/                # Graph generation, node graphs & floor pathfinding
├── campus-compass-tech-spec.md# Campus Compass technical specification
└── floor-*.svg                # Master campus building floor plans
```

---

## 📱 Sub-Projects & Modules

### 1. Flutter Navigation App (`flutter_nav`)
- Interactive vector map rendering of campus buildings and floors using SVG.
- Live indoor positioning via WiFi fingerprinting.
- Multi-floor routing and step-by-step turn guidance.

### 2. Flutter WiFi Survey App (`flutter_survey`)
- Crowdsourced WiFi site survey tool.
- Tap-to-survey on SVG floor plans with real-time AP scans.
- Multi-device survey deduplication and averaging.
- Direct sync to MongoDB Atlas.

### 3. Backend Routing & Positioning Service (`backend`)
- **Flask REST API** (`app.py`, `nav_service.py`): Serves routing and positioning endpoints.
- **WiFi Locator** (`locator.py`): KNN / radio similarity matching between scanned BSSID/RSSI and surveyed fingerprints.
- **Graph Pathfinder** (`navgraph/`): A* / Dijkstra multi-floor routing with staircases and elevators.
- **Database Tools** (`view_db.py`, `validate_data.py`): Data inspection, validation, and dataset export.

---

## 🚀 Getting Started

### Backend Setup
```bash
cd wifi-fingerprint-app/wifi-fingerprint-app/backend
pip install -r requirements.txt
python app.py
```

### Running Flutter Survey App
```bash
cd wifi-fingerprint-app/wifi-fingerprint-app/flutter_survey
flutter pub get
flutter run
```

### Running Flutter Navigation App
```bash
cd wifi-fingerprint-app/wifi-fingerprint-app/flutter_nav
flutter pub get
flutter run
```
