# Campus Compass — Technical Build Spec

A scoped, implementation-ready spec for building the Campus Compass campus navigation app. Written to be handed directly to an agentic coding tool as the primary build prompt.

---

## 1. What to build

A mobile app + backend that lets a user pick a destination on a college campus, get a walking route with live turn-by-turn guidance, and see an animated "mascot" greeting when they arrive at a building. Includes a simple admin CMS for editing building/mascot content.

**MVP scope (build this first):**
- Interactive campus map with search
- GPS-based live navigation with route preview, ETA, turn-by-turn, re-routing
- Building detail sheet (info, hours, contacts, gallery)
- Mascot trigger on arrival (geofence) + manual trigger (tap pin)
- Admin CMS: CRUD for buildings, mascots, events

**Explicitly out of scope for MVP:** indoor navigation, AR, VR tour, face recognition, shuttle tracking, occupancy sensing. (Design the data model so these can be added later — see §7.)

---

## 2. Architecture

```
┌─────────────────┐      ┌──────────────────┐      ┌────────────────────┐
│  Flutter Mobile  │◄────►│   API Gateway /    │◄────►│  PostgreSQL +       │
│  App (iOS/Android)│      │   NestJS Backend   │      │  PostGIS + pgRouting │
└─────────────────┘      └──────────────────┘      └────────────────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
            ┌──────────────┐ ┌──────────┐ ┌────────────────┐
            │ Object Storage│ │ Auth      │ │ Admin CMS       │
            │ (S3/R2) for   │ │ (Supabase │ │ (Next.js) — web │
            │ mascot assets │ │ /Firebase)│ │ for content team│
            └──────────────┘ └──────────┘ └────────────────┘
```

**Stack:**
- **Mobile:** Flutter (Dart), Mapbox GL SDK for Flutter
- **Backend:** Node.js + NestJS, REST API, TypeScript
- **Database:** PostgreSQL 15+ with PostGIS and pgRouting extensions
- **Auth:** Supabase Auth (email/SSO) — only needed for Admin CMS in MVP; end-user app can be anonymous
- **Storage:** S3-compatible bucket (mascot animations, images) behind a CDN
- **Admin CMS:** Next.js web app, calls the same backend API with an admin role token

**Why this stack:** PostGIS/pgRouting gives real shortest-path and accessible-path routing on a graph of campus walkways instead of straight-line approximations. Flutter gives one codebase for iOS/Android with good animation performance for mascot playback. NestJS gives a typed, modular backend that's easy for an agentic tool to extend module-by-module.

---

## 3. Data model

Build these tables first (PostgreSQL + PostGIS):

```sql
-- Buildings / POIs
CREATE TABLE buildings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  category TEXT NOT NULL,        -- academic, admin, hostel, sports, medical, food, parking, emergency, etc.
  geom GEOMETRY(Point, 4326) NOT NULL,
  description TEXT,
  hours TEXT,
  contact TEXT,
  is_accessible BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Mascots (1:1 with buildings for MVP)
CREATE TABLE mascots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  building_id UUID REFERENCES buildings(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  personality TEXT,
  animation_url TEXT,            -- Lottie/Rive JSON in object storage
  greeting_line TEXT NOT NULL,
  facts TEXT[]                   -- array of short fact strings
);

-- Walkway graph (edges) for pgRouting
CREATE TABLE paths (
  id BIGSERIAL PRIMARY KEY,
  geom GEOMETRY(LineString, 4326) NOT NULL,
  is_accessible BOOLEAN DEFAULT true,
  source BIGINT,                 -- filled in by pgr_createTopology
  target BIGINT,
  cost DOUBLE PRECISION,         -- length in meters, computed
  reverse_cost DOUBLE PRECISION
);

-- Rooms/departments (optional for MVP search depth)
CREATE TABLE rooms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  building_id UUID REFERENCES buildings(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  floor INT,
  type TEXT                      -- classroom, lab, office
);

-- Events (powers Event Navigation)
CREATE TABLE events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  venue_id UUID REFERENCES buildings(id),
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  category TEXT
);

CREATE INDEX idx_buildings_geom ON buildings USING GIST (geom);
CREATE INDEX idx_paths_geom ON paths USING GIST (geom);
```

After loading `paths`, run `pgr_createTopology('paths', 0.0001, 'geom', 'id')` to build the routing graph, then query with `pgr_dijkstra` (or `pgr_aStar`) for shortest path, filtering `WHERE is_accessible = true` for accessible routing.

---

## 4. API endpoints (MVP)

All under `/api/v1`, JSON in/out.

| Endpoint | Method | Purpose |
|---|---|---|
| `/search?q=` | GET | Search buildings/rooms by name, fuzzy match |
| `/buildings` | GET | List buildings, filterable by `category` |
| `/buildings/:id` | GET | Full building detail |
| `/mascots/:buildingId` | GET | Mascot payload (animation url, greeting, facts) |
| `/route` | POST | Body: `{ originLat, originLng, destBuildingId, accessible: bool }` → returns polyline, distance_m, eta_min |
| `/events` | GET | Active + upcoming events with venue info |
| `/emergency/contacts` | GET | Static list of emergency POIs and routes |
| `/admin/buildings` | POST/PUT/DELETE | CMS CRUD, requires admin JWT |
| `/admin/mascots` | POST/PUT/DELETE | CMS CRUD, requires admin JWT |
| `/admin/events` | POST/PUT/DELETE | CMS CRUD, requires admin JWT |
| `/analytics/event` | POST | Fire-and-forget client event logging |

**`/route` response shape:**
```json
{
  "distance_m": 420,
  "eta_min": 6,
  "polyline": [[lat, lng], [lat, lng], ...],
  "steps": [
    { "instruction": "Head north on Library Road", "distance_m": 120 },
    { "instruction": "Turn right toward the Engineering Block", "distance_m": 300 }
  ]
}
```

---

## 5. Mobile app structure (Flutter)

```
lib/
├── core/               # theme, constants, api client, location service
├── features/
│   ├── map/            # Mapbox map screen, search bar, category filter
│   ├── navigation/      # route preview, live turn-by-turn, geofence watcher
│   ├── mascots/         # mascot encounter screen, Lottie/Rive player
│   ├── building_detail/ # bottom sheet with info/gallery/hours
│   ├── events/          # event list + one-tap navigation
│   └── emergency/       # emergency panel
└── services/
    ├── api_client.dart
    ├── location_service.dart   # GPS stream, permission handling
    └── geofence_service.dart   # radius check against nearby buildings
```

**Geofence trigger logic (client-side, simplest viable approach for MVP):** every location update, compute distance to all buildings within ~200m (fetched once per map viewport), and if distance < 15m and mascot not yet shown this session, fetch `/mascots/:buildingId` and play the encounter screen.

---

## 6. Build order for the agent

1. Stand up PostgreSQL with PostGIS + pgRouting, run the schema above, seed 5–10 real buildings with coordinates.
2. Build NestJS backend: buildings CRUD, search, `/route` using `pgr_dijkstra`.
3. Build Flutter map screen: render buildings as pins on Mapbox, wire up search.
4. Build route preview + live navigation screen, consuming `/route`.
5. Add mascot data + geofence trigger + mascot encounter screen.
6. Add events + emergency panel (both are thin wrappers around buildings/route).
7. Build the admin CMS (Next.js) last — it's the least user-facing and easiest to bolt on once the API is stable.

---

## 7. Extension points (design for, don't build yet)

- `buildings.floor_plan_id` — nullable FK, ready for indoor nav later.
- `paths.is_accessible` — already supports accessible routing filter today.
- `mascots` table is 1:1 with buildings now; if AR/image-recognition is added later, add a `mascots.marker_image_url` column rather than a new table.
- Keep all mascot dialogue/facts in the database (not hardcoded in the app) so content updates never require an app release.
