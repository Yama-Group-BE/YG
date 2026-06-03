-- ============================================================
-- ABOU PRO LOGISTICS — Supabase Schema v2
-- Idempotent: safe to run multiple times
-- ============================================================

-- ============================================================
-- 0. EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ============================================================
-- 1. UTILITY FUNCTION: set_updated_at (no dependencies)
-- ============================================================
CREATE OR REPLACE FUNCTION aboupro_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- ============================================================
-- 2. TABLE: users_profiles (must be first — others FK to it)
-- ============================================================
CREATE TABLE IF NOT EXISTS users_profiles (
  id            uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  identifier    text NOT NULL UNIQUE,
  full_name     text,
  phone         text,
  role          text NOT NULL DEFAULT 'driver' CHECK (role IN ('admin','driver')),
  is_active     boolean NOT NULL DEFAULT true,
  last_seen_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 3. SECURITY FUNCTIONS (depend on users_profiles)
-- ============================================================

-- aboupro_has_admin(): callable by anon — returns true if any admin exists
CREATE OR REPLACE FUNCTION aboupro_has_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM users_profiles WHERE role = 'admin' AND is_active = true
  );
$$;

-- aboupro_is_admin(): for RLS policies — checks current user role
CREATE OR REPLACE FUNCTION aboupro_is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM users_profiles
    WHERE id = auth.uid() AND role = 'admin' AND is_active = true
  );
$$;

GRANT EXECUTE ON FUNCTION aboupro_has_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION aboupro_is_admin() TO authenticated;

-- ============================================================
-- 4. TABLE: routes
-- ============================================================
CREATE TABLE IF NOT EXISTS routes (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  name          text NOT NULL,
  color         text NOT NULL DEFAULT '#3b82f6',
  description   text,
  is_active     boolean NOT NULL DEFAULT true,
  is_archived   boolean NOT NULL DEFAULT false,
  total_stops   integer NOT NULL DEFAULT 0,
  estimated_km  numeric(8,2),
  created_by    uuid REFERENCES users_profiles(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 5. TABLE: stops
-- ============================================================
CREATE TABLE IF NOT EXISTS stops (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  route_id        uuid NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
  order_index     integer NOT NULL DEFAULT 0,
  client_name     text NOT NULL,
  address         text NOT NULL,
  lat             numeric(10,7),
  lng             numeric(10,7),
  scheduled_time  time,
  days_active     text[] DEFAULT ARRAY['LU','MA','ME','JE','VE'],
  operation_type  text NOT NULL DEFAULT 'livraison' CHECK (operation_type IN ('livraison','collecte','service','autre')),
  notes           text,
  access_code     text,
  parking_info    text,
  requires_photo  boolean NOT NULL DEFAULT false,
  requires_scan   boolean NOT NULL DEFAULT false,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 6. TABLE: assignments
-- ============================================================
CREATE TABLE IF NOT EXISTS assignments (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  route_id        uuid NOT NULL REFERENCES routes(id) ON DELETE RESTRICT,
  driver_id       uuid NOT NULL REFERENCES users_profiles(id) ON DELETE RESTRICT,
  assigned_date   date NOT NULL,
  vehicle_type    text NOT NULL DEFAULT 'voiture' CHECK (vehicle_type IN ('pied','velo','voiture','camionnette','camion')),
  start_time      time,
  end_time_max    time,
  status          text NOT NULL DEFAULT 'planifie' CHECK (status IN ('planifie','en_cours','termine','incident','annule')),
  notes           text,
  started_at      timestamptz,
  completed_at    timestamptz,
  total_stops     integer NOT NULL DEFAULT 0,
  done_stops      integer NOT NULL DEFAULT 0,
  problem_stops   integer NOT NULL DEFAULT 0,
  total_km        numeric(8,2),
  created_by      uuid REFERENCES users_profiles(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 7. TABLE: assignment_stops
-- ============================================================
CREATE TABLE IF NOT EXISTS assignment_stops (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  assignment_id   uuid NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
  stop_id         uuid NOT NULL REFERENCES stops(id) ON DELETE CASCADE,
  order_index     integer NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','problem','skipped')),
  arrived_at      timestamptz,
  completed_at    timestamptz,
  lat_arrived     numeric(10,7),
  lng_arrived     numeric(10,7),
  distance_m      integer,
  problem_type    text,
  problem_notes   text,
  scan_code       text,
  photo_taken     boolean NOT NULL DEFAULT false,
  scan_done       boolean NOT NULL DEFAULT false,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (assignment_id, stop_id)
);

-- ============================================================
-- 8. TABLE: tour_logs
-- ============================================================
CREATE TABLE IF NOT EXISTS tour_logs (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  assignment_id   uuid NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
  driver_id       uuid NOT NULL REFERENCES users_profiles(id) ON DELETE CASCADE,
  event_type      text NOT NULL CHECK (event_type IN (
    'tour_started','tour_paused','tour_resumed','tour_completed',
    'stop_arrived','stop_done','stop_problem','stop_skipped',
    'photo_taken','scan_done','gps_outside_range'
  )),
  stop_id         uuid REFERENCES stops(id) ON DELETE SET NULL,
  payload         jsonb,
  lat             numeric(10,7),
  lng             numeric(10,7),
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 9. TABLE: photos
-- ============================================================
CREATE TABLE IF NOT EXISTS photos (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  assignment_id   uuid NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
  stop_id         uuid REFERENCES stops(id) ON DELETE SET NULL,
  driver_id       uuid NOT NULL REFERENCES users_profiles(id) ON DELETE CASCADE,
  storage_path    text NOT NULL,
  photo_type      text NOT NULL DEFAULT 'delivery' CHECK (photo_type IN ('delivery','problem','other')),
  taken_at        timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 10. TABLE: driver_positions
-- ============================================================
CREATE TABLE IF NOT EXISTS driver_positions (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  driver_id       uuid NOT NULL REFERENCES users_profiles(id) ON DELETE CASCADE,
  assignment_id   uuid REFERENCES assignments(id) ON DELETE SET NULL,
  lat             numeric(10,7) NOT NULL,
  lng             numeric(10,7) NOT NULL,
  accuracy_m      integer,
  heading         numeric(5,2),
  speed_kmh       numeric(6,2),
  recorded_at     timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (driver_id, recorded_at)
);

-- ============================================================
-- 11. UPDATED_AT TRIGGERS (loop for all tables that need it)
-- ============================================================
DO $$
DECLARE
  tbl text;
  tbl_list text[] := ARRAY[
    'users_profiles',
    'routes',
    'stops',
    'assignments',
    'assignment_stops'
  ];
BEGIN
  FOREACH tbl IN ARRAY tbl_list LOOP
    -- Drop existing trigger (if any) then recreate
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I',
      tbl, tbl
    );
    EXECUTE format(
      'CREATE TRIGGER trg_%s_updated_at
       BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION aboupro_set_updated_at()',
      tbl, tbl
    );
  END LOOP;
END;
$$;

-- ============================================================
-- 12. INDEXES
-- ============================================================
-- users_profiles
CREATE INDEX IF NOT EXISTS idx_users_profiles_role       ON users_profiles(role);
CREATE INDEX IF NOT EXISTS idx_users_profiles_identifier ON users_profiles(identifier);

-- routes
CREATE INDEX IF NOT EXISTS idx_routes_is_active    ON routes(is_active);
CREATE INDEX IF NOT EXISTS idx_routes_is_archived  ON routes(is_archived);

-- stops
CREATE INDEX IF NOT EXISTS idx_stops_route_id     ON stops(route_id);
CREATE INDEX IF NOT EXISTS idx_stops_order_index  ON stops(route_id, order_index);
CREATE INDEX IF NOT EXISTS idx_stops_address_trgm ON stops USING gin(address gin_trgm_ops);

-- assignments
CREATE INDEX IF NOT EXISTS idx_assignments_driver_id      ON assignments(driver_id);
CREATE INDEX IF NOT EXISTS idx_assignments_route_id       ON assignments(route_id);
CREATE INDEX IF NOT EXISTS idx_assignments_assigned_date  ON assignments(assigned_date);
CREATE INDEX IF NOT EXISTS idx_assignments_status         ON assignments(status);
CREATE INDEX IF NOT EXISTS idx_assignments_date_driver    ON assignments(assigned_date, driver_id);

-- assignment_stops
CREATE INDEX IF NOT EXISTS idx_assignment_stops_assignment ON assignment_stops(assignment_id);
CREATE INDEX IF NOT EXISTS idx_assignment_stops_stop       ON assignment_stops(stop_id);
CREATE INDEX IF NOT EXISTS idx_assignment_stops_status     ON assignment_stops(status);

-- tour_logs
CREATE INDEX IF NOT EXISTS idx_tour_logs_assignment  ON tour_logs(assignment_id);
CREATE INDEX IF NOT EXISTS idx_tour_logs_driver      ON tour_logs(driver_id);
CREATE INDEX IF NOT EXISTS idx_tour_logs_created_at  ON tour_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tour_logs_event_type  ON tour_logs(event_type);

-- photos
CREATE INDEX IF NOT EXISTS idx_photos_assignment ON photos(assignment_id);
CREATE INDEX IF NOT EXISTS idx_photos_driver     ON photos(driver_id);
CREATE INDEX IF NOT EXISTS idx_photos_stop       ON photos(stop_id);

-- driver_positions
CREATE INDEX IF NOT EXISTS idx_driver_positions_driver      ON driver_positions(driver_id);
CREATE INDEX IF NOT EXISTS idx_driver_positions_recorded_at ON driver_positions(recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_driver_positions_assignment  ON driver_positions(assignment_id);

-- ============================================================
-- 13. ROW LEVEL SECURITY
-- ============================================================
-- Enable RLS on all tables
DO $$
DECLARE
  tbl text;
  tbl_list text[] := ARRAY[
    'users_profiles','routes','stops','assignments',
    'assignment_stops','tour_logs','photos','driver_positions'
  ];
BEGIN
  FOREACH tbl IN ARRAY tbl_list LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
  END LOOP;
END;
$$;

-- Drop all existing policies (idempotent cleanup)
DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT policyname, tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN (
        'users_profiles','routes','stops','assignments',
        'assignment_stops','tour_logs','photos','driver_positions'
      )
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', pol.policyname, pol.tablename);
  END LOOP;
END;
$$;

-- ---- users_profiles ----
CREATE POLICY "admin_all_profiles" ON users_profiles
  FOR ALL TO authenticated
  USING (aboupro_is_admin())
  WITH CHECK (aboupro_is_admin());

CREATE POLICY "driver_own_profile" ON users_profiles
  FOR SELECT TO authenticated
  USING (id = auth.uid());

CREATE POLICY "driver_update_own_profile" ON users_profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- Allow insert so new users can create their own profile row
CREATE POLICY "user_insert_own_profile" ON users_profiles
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

-- ---- routes ----
CREATE POLICY "admin_all_routes" ON routes
  FOR ALL TO authenticated
  USING (aboupro_is_admin())
  WITH CHECK (aboupro_is_admin());

CREATE POLICY "driver_read_active_routes" ON routes
  FOR SELECT TO authenticated
  USING (is_active = true AND is_archived = false);

-- ---- stops ----
CREATE POLICY "admin_all_stops" ON stops
  FOR ALL TO authenticated
  USING (aboupro_is_admin())
  WITH CHECK (aboupro_is_admin());

CREATE POLICY "driver_read_stops" ON stops
  FOR SELECT TO authenticated
  USING (
    is_active = true AND EXISTS (
      SELECT 1 FROM routes r WHERE r.id = stops.route_id AND r.is_active = true
    )
  );

-- ---- assignments ----
CREATE POLICY "admin_all_assignments" ON assignments
  FOR ALL TO authenticated
  USING (aboupro_is_admin())
  WITH CHECK (aboupro_is_admin());

CREATE POLICY "driver_own_assignments" ON assignments
  FOR SELECT TO authenticated
  USING (driver_id = auth.uid());

CREATE POLICY "driver_update_own_assignment" ON assignments
  FOR UPDATE TO authenticated
  USING (driver_id = auth.uid())
  WITH CHECK (driver_id = auth.uid());

-- ---- assignment_stops ----
CREATE POLICY "admin_all_assignment_stops" ON assignment_stops
  FOR ALL TO authenticated
  USING (aboupro_is_admin())
  WITH CHECK (aboupro_is_admin());

CREATE POLICY "driver_own_assignment_stops_select" ON assignment_stops
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM assignments a
      WHERE a.id = assignment_stops.assignment_id AND a.driver_id = auth.uid()
    )
  );

CREATE POLICY "driver_own_assignment_stops_update" ON assignment_stops
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM assignments a
      WHERE a.id = assignment_stops.assignment_id AND a.driver_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM assignments a
      WHERE a.id = assignment_stops.assignment_id AND a.driver_id = auth.uid()
    )
  );

-- ---- tour_logs ----
CREATE POLICY "admin_all_tour_logs" ON tour_logs
  FOR ALL TO authenticated
  USING (aboupro_is_admin())
  WITH CHECK (aboupro_is_admin());

CREATE POLICY "driver_own_tour_logs_select" ON tour_logs
  FOR SELECT TO authenticated
  USING (driver_id = auth.uid());

CREATE POLICY "driver_own_tour_logs_insert" ON tour_logs
  FOR INSERT TO authenticated
  WITH CHECK (driver_id = auth.uid());

-- ---- photos ----
CREATE POLICY "admin_all_photos" ON photos
  FOR ALL TO authenticated
  USING (aboupro_is_admin())
  WITH CHECK (aboupro_is_admin());

CREATE POLICY "driver_own_photos_select" ON photos
  FOR SELECT TO authenticated
  USING (driver_id = auth.uid());

CREATE POLICY "driver_own_photos_insert" ON photos
  FOR INSERT TO authenticated
  WITH CHECK (driver_id = auth.uid());

-- ---- driver_positions ----
CREATE POLICY "admin_all_driver_positions" ON driver_positions
  FOR ALL TO authenticated
  USING (aboupro_is_admin())
  WITH CHECK (aboupro_is_admin());

CREATE POLICY "driver_own_positions_select" ON driver_positions
  FOR SELECT TO authenticated
  USING (driver_id = auth.uid());

CREATE POLICY "driver_own_positions_insert" ON driver_positions
  FOR INSERT TO authenticated
  WITH CHECK (driver_id = auth.uid());

CREATE POLICY "driver_own_positions_update" ON driver_positions
  FOR UPDATE TO authenticated
  USING (driver_id = auth.uid())
  WITH CHECK (driver_id = auth.uid());

-- ============================================================
-- 14. REALTIME PUBLICATION (with existence check)
-- ============================================================
DO $$
DECLARE
  tbl text;
  tbl_list text[] := ARRAY[
    'assignments','assignment_stops','tour_logs',
    'driver_positions','routes','stops','photos'
  ];
BEGIN
  -- Create publication if not exists
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) THEN
    EXECUTE 'CREATE PUBLICATION supabase_realtime FOR TABLE ' ||
      array_to_string(tbl_list, ', ');
  ELSE
    FOREACH tbl IN ARRAY tbl_list LOOP
      BEGIN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %I', tbl);
      EXCEPTION WHEN others THEN
        -- table already in publication, ignore
        NULL;
      END;
    END LOOP;
  END IF;
END;
$$;

-- ============================================================
-- 15. VIEWS
-- ============================================================

-- Drop and recreate views (idempotent)
DROP VIEW IF EXISTS aboupro_assignments_view CASCADE;
DROP VIEW IF EXISTS aboupro_driver_kpis CASCADE;

CREATE VIEW aboupro_assignments_view AS
SELECT
  a.id,
  a.assigned_date,
  a.vehicle_type,
  a.status,
  a.start_time,
  a.end_time_max,
  a.started_at,
  a.completed_at,
  a.total_stops,
  a.done_stops,
  a.problem_stops,
  a.total_km,
  a.notes,
  a.created_at,
  -- Route info
  r.id           AS route_id,
  r.name         AS route_name,
  r.color        AS route_color,
  r.estimated_km AS route_estimated_km,
  -- Driver info
  d.id           AS driver_id,
  d.identifier   AS driver_identifier,
  d.full_name    AS driver_name,
  d.phone        AS driver_phone,
  -- Progress
  CASE WHEN a.total_stops > 0
    THEN round((a.done_stops::numeric / a.total_stops::numeric) * 100, 1)
    ELSE 0
  END AS progress_pct
FROM assignments a
JOIN routes r          ON r.id = a.route_id
JOIN users_profiles d  ON d.id = a.driver_id;

CREATE VIEW aboupro_driver_kpis AS
SELECT
  d.id              AS driver_id,
  d.identifier      AS driver_identifier,
  d.full_name       AS driver_name,
  COUNT(a.id)                                                  AS total_assignments,
  COUNT(a.id) FILTER (WHERE a.status = 'termine')              AS completed_assignments,
  COUNT(a.id) FILTER (WHERE a.status = 'incident')             AS incident_assignments,
  COALESCE(SUM(a.done_stops), 0)                               AS total_stops_done,
  COALESCE(SUM(a.problem_stops), 0)                            AS total_stops_problem,
  COALESCE(SUM(a.total_km), 0)                                 AS total_km,
  CASE
    WHEN COUNT(a.id) FILTER (WHERE a.status IN ('termine','incident')) > 0
    THEN round(
      COUNT(a.id) FILTER (WHERE a.status = 'termine')::numeric
      / COUNT(a.id) FILTER (WHERE a.status IN ('termine','incident'))::numeric * 100, 1
    )
    ELSE 0
  END AS success_rate_pct,
  -- Last position
  (SELECT dp.lat FROM driver_positions dp
   WHERE dp.driver_id = d.id ORDER BY dp.recorded_at DESC LIMIT 1) AS last_lat,
  (SELECT dp.lng FROM driver_positions dp
   WHERE dp.driver_id = d.id ORDER BY dp.recorded_at DESC LIMIT 1) AS last_lng,
  (SELECT dp.recorded_at FROM driver_positions dp
   WHERE dp.driver_id = d.id ORDER BY dp.recorded_at DESC LIMIT 1) AS last_position_at
FROM users_profiles d
LEFT JOIN assignments a ON a.driver_id = d.id
WHERE d.role = 'driver'
GROUP BY d.id, d.identifier, d.full_name;

-- ============================================================
-- 16. STORAGE BUCKET (abou-pro-photos)
-- ============================================================
DO $$
BEGIN
  INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  VALUES (
    'abou-pro-photos',
    'abou-pro-photos',
    false,
    5242880, -- 5 MB
    ARRAY['image/jpeg','image/png','image/webp']
  )
  ON CONFLICT (id) DO NOTHING;
EXCEPTION WHEN others THEN NULL;
END;
$$;

-- Storage RLS
DO $$
BEGIN
  -- Drop existing storage policies for this bucket
  DELETE FROM storage.policies
  WHERE bucket_id = 'abou-pro-photos';
EXCEPTION WHEN others THEN NULL;
END;
$$;

-- ============================================================
-- 17. HELPER FUNCTION: update assignment progress
-- ============================================================
CREATE OR REPLACE FUNCTION aboupro_update_assignment_progress(p_assignment_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE assignments SET
    done_stops    = (SELECT COUNT(*) FROM assignment_stops WHERE assignment_id = p_assignment_id AND status = 'done'),
    problem_stops = (SELECT COUNT(*) FROM assignment_stops WHERE assignment_id = p_assignment_id AND status = 'problem'),
    total_stops   = (SELECT COUNT(*) FROM assignment_stops WHERE assignment_id = p_assignment_id),
    updated_at    = now()
  WHERE id = p_assignment_id;
END;
$$;

GRANT EXECUTE ON FUNCTION aboupro_update_assignment_progress(uuid) TO authenticated;

-- Trigger to auto-update progress when an assignment_stop changes
CREATE OR REPLACE FUNCTION aboupro_trigger_update_progress()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM aboupro_update_assignment_progress(
    COALESCE(NEW.assignment_id, OLD.assignment_id)
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assignment_stops_progress ON assignment_stops;
CREATE TRIGGER trg_assignment_stops_progress
  AFTER INSERT OR UPDATE OR DELETE ON assignment_stops
  FOR EACH ROW EXECUTE FUNCTION aboupro_trigger_update_progress();

-- ============================================================
-- 18. HELPER FUNCTION: get today's driver summary
-- ============================================================
CREATE OR REPLACE FUNCTION aboupro_today_summary()
RETURNS TABLE (
  active_routes   bigint,
  total_drivers   bigint,
  tours_today     bigint,
  avg_progress    numeric
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT
    (SELECT COUNT(*) FROM routes WHERE is_active = true AND is_archived = false),
    (SELECT COUNT(*) FROM users_profiles WHERE role = 'driver' AND is_active = true),
    (SELECT COUNT(*) FROM assignments WHERE assigned_date = CURRENT_DATE),
    COALESCE((
      SELECT AVG(
        CASE WHEN total_stops > 0
          THEN (done_stops::numeric / total_stops::numeric) * 100
          ELSE 0
        END
      )
      FROM assignments WHERE assigned_date = CURRENT_DATE
    ), 0)
  ;
$$;

GRANT EXECUTE ON FUNCTION aboupro_today_summary() TO authenticated;

-- ============================================================
-- 19. FINAL VERIFICATION
-- ============================================================
SELECT
  table_name,
  (SELECT COUNT(*) FROM information_schema.columns c
   WHERE c.table_name = t.table_name AND c.table_schema = 'public') AS column_count
FROM (VALUES
  ('users_profiles'),
  ('routes'),
  ('stops'),
  ('assignments'),
  ('assignment_stops'),
  ('tour_logs'),
  ('photos'),
  ('driver_positions')
) AS t(table_name)
ORDER BY table_name;

-- ============================================================
-- DONE — ABOU PRO schema v2 installed successfully
-- ============================================================
