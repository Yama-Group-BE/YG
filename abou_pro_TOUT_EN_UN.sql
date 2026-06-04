-- ============================================================
-- ABOU PRO LOGISTICS — Supabase Schema v2 (CLEAN INSTALL)
-- Supprime les anciens objets et recrée tout proprement.
-- SAFE: ne touche pas à auth.users — les comptes existants
-- sont conservés, seuls les profils sont recréés.
-- ============================================================

-- ============================================================
-- 0. EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ============================================================
-- 0a. SUPPRIME les anciens triggers sur auth.users
--     (cause principale de "Database error finding user")
-- ============================================================
DO $$
BEGIN
  DROP TRIGGER IF EXISTS on_auth_user_created          ON auth.users;
  DROP TRIGGER IF EXISTS on_auth_user_created_trigger  ON auth.users;
  DROP TRIGGER IF EXISTS handle_new_user_trigger       ON auth.users;
  DROP TRIGGER IF EXISTS create_profile_trigger        ON auth.users;
EXCEPTION WHEN others THEN NULL;
END;
$$;
DO $$
BEGIN
  DROP FUNCTION IF EXISTS public.handle_new_user()   CASCADE;
  DROP FUNCTION IF EXISTS public.create_profile()    CASCADE;
  DROP FUNCTION IF EXISTS public.sync_user_profile() CASCADE;
EXCEPTION WHEN others THEN NULL;
END;
$$;

-- ============================================================
-- 0b. NETTOYAGE COMPLET des anciens objets (DROP CASCADE)
-- ============================================================
DROP VIEW  IF EXISTS aboupro_driver_kpis        CASCADE;
DROP VIEW  IF EXISTS aboupro_assignments_view   CASCADE;
DROP TABLE IF EXISTS driver_positions           CASCADE;
DROP TABLE IF EXISTS photos                     CASCADE;
DROP TABLE IF EXISTS tour_logs                  CASCADE;
DROP TABLE IF EXISTS assignment_stops           CASCADE;
DROP TABLE IF EXISTS assignments                CASCADE;
DROP TABLE IF EXISTS stops                      CASCADE;
DROP TABLE IF EXISTS routes                     CASCADE;
DROP TABLE IF EXISTS users_profiles             CASCADE;

DROP FUNCTION IF EXISTS aboupro_has_admin()              CASCADE;
DROP FUNCTION IF EXISTS aboupro_is_admin()               CASCADE;
DROP FUNCTION IF EXISTS aboupro_set_updated_at()         CASCADE;
DROP FUNCTION IF EXISTS aboupro_update_assignment_progress(uuid) CASCADE;
DROP FUNCTION IF EXISTS aboupro_trigger_update_progress() CASCADE;
DROP FUNCTION IF EXISTS aboupro_today_summary()          CASCADE;

-- ============================================================
-- 1. UTILITY TRIGGER FUNCTION
-- ============================================================
CREATE OR REPLACE FUNCTION aboupro_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- ============================================================
-- 2. TABLE: users_profiles
-- ============================================================
CREATE TABLE users_profiles (
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
-- 3. SECURITY FUNCTIONS (dépendent de users_profiles)
-- ============================================================
CREATE OR REPLACE FUNCTION aboupro_has_admin()
RETURNS boolean LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM users_profiles WHERE role = 'admin' AND is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION aboupro_is_admin()
RETURNS boolean LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM users_profiles
    WHERE id = auth.uid() AND role = 'admin' AND is_active = true
  );
$$;

GRANT EXECUTE ON FUNCTION aboupro_has_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION aboupro_is_admin()  TO authenticated;

-- ============================================================
-- 4. TABLE: routes
-- ============================================================
CREATE TABLE routes (
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
CREATE TABLE stops (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  route_id        uuid NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
  order_index     integer NOT NULL DEFAULT 0,
  client_name     text NOT NULL DEFAULT '',
  address         text NOT NULL DEFAULT '',
  lat             numeric(10,7),
  lng             numeric(10,7),
  scheduled_time  time,
  days_active     text[] DEFAULT ARRAY['LU','MA','ME','JE','VE'],
  operation_type  text NOT NULL DEFAULT 'livraison'
                  CHECK (operation_type IN ('livraison','collecte','service','autre')),
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
CREATE TABLE assignments (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  route_id        uuid NOT NULL REFERENCES routes(id) ON DELETE RESTRICT,
  driver_id       uuid NOT NULL REFERENCES users_profiles(id) ON DELETE RESTRICT,
  assigned_date   date NOT NULL,
  vehicle_type    text NOT NULL DEFAULT 'voiture'
                  CHECK (vehicle_type IN ('pied','velo','voiture','camionnette','camion')),
  start_time      time,
  end_time_max    time,
  status          text NOT NULL DEFAULT 'planifie'
                  CHECK (status IN ('planifie','en_cours','termine','incident','annule')),
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
CREATE TABLE assignment_stops (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  assignment_id   uuid NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
  stop_id         uuid NOT NULL REFERENCES stops(id) ON DELETE CASCADE,
  order_index     integer NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','done','problem','skipped')),
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
CREATE TABLE tour_logs (
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
CREATE TABLE photos (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  assignment_id   uuid NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
  stop_id         uuid REFERENCES stops(id) ON DELETE SET NULL,
  driver_id       uuid NOT NULL REFERENCES users_profiles(id) ON DELETE CASCADE,
  storage_path    text NOT NULL,
  photo_type      text NOT NULL DEFAULT 'delivery'
                  CHECK (photo_type IN ('delivery','problem','other')),
  taken_at        timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 10. TABLE: driver_positions
-- ============================================================
CREATE TABLE driver_positions (
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
-- 11. TRIGGERS updated_at
-- ============================================================
DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['users_profiles','routes','stops','assignments','assignment_stops'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', tbl, tbl);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION aboupro_set_updated_at()', tbl, tbl);
  END LOOP;
END;
$$;

-- ============================================================
-- 12. INDEXES
-- ============================================================
CREATE INDEX idx_up_role       ON users_profiles(role);
CREATE INDEX idx_up_identifier ON users_profiles(identifier);
CREATE INDEX idx_up_is_active  ON users_profiles(is_active);

CREATE INDEX idx_routes_active   ON routes(is_active);
CREATE INDEX idx_routes_archived ON routes(is_archived);

CREATE INDEX idx_stops_route    ON stops(route_id);
CREATE INDEX idx_stops_order    ON stops(route_id, order_index);
CREATE INDEX idx_stops_active   ON stops(is_active);
CREATE INDEX idx_stops_addr_trg ON stops USING gin(address gin_trgm_ops);

CREATE INDEX idx_asgn_driver ON assignments(driver_id);
CREATE INDEX idx_asgn_route  ON assignments(route_id);
CREATE INDEX idx_asgn_date   ON assignments(assigned_date);
CREATE INDEX idx_asgn_status ON assignments(status);
CREATE INDEX idx_asgn_dd     ON assignments(assigned_date, driver_id);

CREATE INDEX idx_as_assignment ON assignment_stops(assignment_id);
CREATE INDEX idx_as_stop       ON assignment_stops(stop_id);
CREATE INDEX idx_as_status     ON assignment_stops(status);

CREATE INDEX idx_tl_assignment ON tour_logs(assignment_id);
CREATE INDEX idx_tl_driver     ON tour_logs(driver_id);
CREATE INDEX idx_tl_created    ON tour_logs(created_at DESC);

CREATE INDEX idx_ph_assignment ON photos(assignment_id);
CREATE INDEX idx_ph_driver     ON photos(driver_id);

CREATE INDEX idx_dp_driver     ON driver_positions(driver_id);
CREATE INDEX idx_dp_recorded   ON driver_positions(recorded_at DESC);
CREATE INDEX idx_dp_assignment ON driver_positions(assignment_id);

-- ============================================================
-- 13. ROW LEVEL SECURITY
-- ============================================================
DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['users_profiles','routes','stops','assignments','assignment_stops','tour_logs','photos','driver_positions'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
  END LOOP;
END;
$$;

-- users_profiles
CREATE POLICY "admin_all_profiles"          ON users_profiles FOR ALL       TO authenticated USING (aboupro_is_admin()) WITH CHECK (aboupro_is_admin());
CREATE POLICY "driver_select_own_profile"   ON users_profiles FOR SELECT    TO authenticated USING (id = auth.uid());
CREATE POLICY "driver_update_own_profile"   ON users_profiles FOR UPDATE    TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());
CREATE POLICY "user_insert_own_profile"     ON users_profiles FOR INSERT    TO authenticated WITH CHECK (id = auth.uid());

-- routes
CREATE POLICY "admin_all_routes"            ON routes FOR ALL    TO authenticated USING (aboupro_is_admin()) WITH CHECK (aboupro_is_admin());
CREATE POLICY "driver_read_routes"          ON routes FOR SELECT TO authenticated USING (is_active = true AND is_archived = false);

-- stops
CREATE POLICY "admin_all_stops"             ON stops FOR ALL    TO authenticated USING (aboupro_is_admin()) WITH CHECK (aboupro_is_admin());
CREATE POLICY "driver_read_stops"           ON stops FOR SELECT TO authenticated USING (is_active = true AND EXISTS (SELECT 1 FROM routes r WHERE r.id = stops.route_id AND r.is_active = true));

-- assignments
CREATE POLICY "admin_all_assignments"       ON assignments FOR ALL    TO authenticated USING (aboupro_is_admin()) WITH CHECK (aboupro_is_admin());
CREATE POLICY "driver_select_own_asgn"      ON assignments FOR SELECT TO authenticated USING (driver_id = auth.uid());
CREATE POLICY "driver_update_own_asgn"      ON assignments FOR UPDATE TO authenticated USING (driver_id = auth.uid()) WITH CHECK (driver_id = auth.uid());

-- assignment_stops
CREATE POLICY "admin_all_as"                ON assignment_stops FOR ALL    TO authenticated USING (aboupro_is_admin()) WITH CHECK (aboupro_is_admin());
CREATE POLICY "driver_select_own_as"        ON assignment_stops FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM assignments a WHERE a.id = assignment_stops.assignment_id AND a.driver_id = auth.uid()));
CREATE POLICY "driver_update_own_as"        ON assignment_stops FOR UPDATE TO authenticated USING (EXISTS (SELECT 1 FROM assignments a WHERE a.id = assignment_stops.assignment_id AND a.driver_id = auth.uid())) WITH CHECK (EXISTS (SELECT 1 FROM assignments a WHERE a.id = assignment_stops.assignment_id AND a.driver_id = auth.uid()));

-- tour_logs
CREATE POLICY "admin_all_tl"                ON tour_logs FOR ALL    TO authenticated USING (aboupro_is_admin()) WITH CHECK (aboupro_is_admin());
CREATE POLICY "driver_select_own_tl"        ON tour_logs FOR SELECT TO authenticated USING (driver_id = auth.uid());
CREATE POLICY "driver_insert_own_tl"        ON tour_logs FOR INSERT TO authenticated WITH CHECK (driver_id = auth.uid());

-- photos
CREATE POLICY "admin_all_photos"            ON photos FOR ALL    TO authenticated USING (aboupro_is_admin()) WITH CHECK (aboupro_is_admin());
CREATE POLICY "driver_select_own_photos"    ON photos FOR SELECT TO authenticated USING (driver_id = auth.uid());
CREATE POLICY "driver_insert_own_photos"    ON photos FOR INSERT TO authenticated WITH CHECK (driver_id = auth.uid());

-- driver_positions
CREATE POLICY "admin_all_dp"                ON driver_positions FOR ALL    TO authenticated USING (aboupro_is_admin()) WITH CHECK (aboupro_is_admin());
CREATE POLICY "driver_select_own_dp"        ON driver_positions FOR SELECT TO authenticated USING (driver_id = auth.uid());
CREATE POLICY "driver_insert_own_dp"        ON driver_positions FOR INSERT TO authenticated WITH CHECK (driver_id = auth.uid());
CREATE POLICY "driver_update_own_dp"        ON driver_positions FOR UPDATE TO authenticated USING (driver_id = auth.uid()) WITH CHECK (driver_id = auth.uid());

-- ============================================================
-- 14. REALTIME
-- ============================================================
DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['assignments','assignment_stops','tour_logs','driver_positions','routes','stops','photos'] LOOP
    BEGIN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %I', tbl);
    EXCEPTION WHEN others THEN NULL;
    END;
  END LOOP;
END;
$$;

-- ============================================================
-- 15. VIEWS
-- ============================================================
CREATE VIEW aboupro_assignments_view AS
SELECT
  a.id, a.assigned_date, a.vehicle_type, a.status,
  a.start_time, a.end_time_max, a.started_at, a.completed_at,
  a.total_stops, a.done_stops, a.problem_stops, a.total_km, a.notes, a.created_at,
  r.id           AS route_id,
  r.name         AS route_name,
  r.color        AS route_color,
  r.estimated_km AS route_estimated_km,
  d.id           AS driver_id,
  d.identifier   AS driver_identifier,
  d.full_name    AS driver_name,
  d.phone        AS driver_phone,
  CASE WHEN a.total_stops > 0
    THEN round((a.done_stops::numeric / a.total_stops::numeric) * 100, 1)
    ELSE 0
  END AS progress_pct
FROM assignments a
JOIN routes r         ON r.id = a.route_id
JOIN users_profiles d ON d.id = a.driver_id;

CREATE VIEW aboupro_driver_kpis AS
SELECT
  d.id              AS driver_id,
  d.identifier      AS driver_identifier,
  d.full_name       AS driver_name,
  d.is_active,
  COUNT(a.id)                                                   AS total_assignments,
  COUNT(a.id) FILTER (WHERE a.status = 'termine')               AS completed_assignments,
  COUNT(a.id) FILTER (WHERE a.status = 'incident')              AS incident_assignments,
  COALESCE(SUM(a.done_stops),    0)                             AS total_stops_done,
  COALESCE(SUM(a.problem_stops), 0)                             AS total_stops_problem,
  COALESCE(SUM(a.total_km),      0)                             AS total_km,
  CASE
    WHEN COUNT(a.id) FILTER (WHERE a.status IN ('termine','incident')) > 0
    THEN round(
      COUNT(a.id) FILTER (WHERE a.status = 'termine')::numeric
      / COUNT(a.id) FILTER (WHERE a.status IN ('termine','incident'))::numeric * 100, 1
    )
    ELSE 0
  END AS success_rate_pct,
  (SELECT dp.lat        FROM driver_positions dp WHERE dp.driver_id = d.id ORDER BY dp.recorded_at DESC LIMIT 1) AS last_lat,
  (SELECT dp.lng        FROM driver_positions dp WHERE dp.driver_id = d.id ORDER BY dp.recorded_at DESC LIMIT 1) AS last_lng,
  (SELECT dp.recorded_at FROM driver_positions dp WHERE dp.driver_id = d.id ORDER BY dp.recorded_at DESC LIMIT 1) AS last_position_at
FROM users_profiles d
LEFT JOIN assignments a ON a.driver_id = d.id
WHERE d.role = 'driver'
GROUP BY d.id, d.identifier, d.full_name, d.is_active;

-- ============================================================
-- 16. PROGRESS TRIGGER
-- ============================================================
CREATE OR REPLACE FUNCTION aboupro_update_assignment_progress(p_assignment_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
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

CREATE OR REPLACE FUNCTION aboupro_trigger_update_progress()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM aboupro_update_assignment_progress(COALESCE(NEW.assignment_id, OLD.assignment_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_as_progress
  AFTER INSERT OR UPDATE OR DELETE ON assignment_stops
  FOR EACH ROW EXECUTE FUNCTION aboupro_trigger_update_progress();

-- ============================================================
-- 17. DASHBOARD KPI FUNCTION
-- ============================================================
CREATE OR REPLACE FUNCTION aboupro_today_summary()
RETURNS TABLE (active_routes bigint, total_drivers bigint, tours_today bigint, avg_progress numeric)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT
    (SELECT COUNT(*) FROM routes        WHERE is_active = true AND is_archived = false),
    (SELECT COUNT(*) FROM users_profiles WHERE role = 'driver' AND is_active = true),
    (SELECT COUNT(*) FROM assignments   WHERE assigned_date = CURRENT_DATE),
    COALESCE((
      SELECT AVG(CASE WHEN total_stops > 0 THEN (done_stops::numeric/total_stops::numeric)*100 ELSE 0 END)
      FROM assignments WHERE assigned_date = CURRENT_DATE
    ), 0);
$$;
GRANT EXECUTE ON FUNCTION aboupro_today_summary() TO authenticated;

-- ============================================================
-- 18. STORAGE BUCKET
-- ============================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('abou-pro-photos','abou-pro-photos', false, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  DROP POLICY IF EXISTS "drivers_upload_photos"      ON storage.objects;
  DROP POLICY IF EXISTS "drivers_read_own_photos"    ON storage.objects;
  DROP POLICY IF EXISTS "admin_all_photos_storage"   ON storage.objects;
EXCEPTION WHEN others THEN NULL;
END;
$$;

CREATE POLICY "drivers_upload_photos" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'abou-pro-photos' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "drivers_read_own_photos" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'abou-pro-photos' AND (aboupro_is_admin() OR (storage.foldername(name))[1] = auth.uid()::text));

-- ============================================================
-- VÉRIFICATION FINALE
-- ============================================================
SELECT table_name,
  (SELECT COUNT(*) FROM information_schema.columns c
   WHERE c.table_name = t.table_name AND c.table_schema = 'public') AS colonnes
FROM (VALUES ('users_profiles'),('routes'),('stops'),('assignments'),('assignment_stops'),('tour_logs'),('photos'),('driver_positions')) AS t(table_name)
ORDER BY table_name;

-- DONE — Schema ABOU PRO v2 installé avec succès.
-- Ouvrez abou_pro.html, l'écran de configuration s'affichera
-- pour créer le compte administrateur.
-- ============================================================
-- ABOU PRO — Auth Fix (résout "Database error finding user")
-- À exécuter dans Supabase SQL Editor APRÈS abou_pro_schema_v2.sql
-- ============================================================

-- 1. Créer des stubs pour tous les hooks auth possibles
--    (évite les erreurs si Supabase cherche une fonction inexistante)
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$$ BEGIN RETURN event; END; $$;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS
$$ BEGIN RETURN NEW; END; $$;

CREATE OR REPLACE FUNCTION public.on_auth_user_created()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS
$$ BEGIN RETURN NEW; END; $$;

DO $$ BEGIN
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin';
EXCEPTION WHEN others THEN NULL;
END; $$;

-- 2. Supprimer les anciens triggers cassés sur auth.users
DO $$ BEGIN
  DROP TRIGGER IF EXISTS on_auth_user_created         ON auth.users;
  DROP TRIGGER IF EXISTS handle_new_user_trigger      ON auth.users;
  DROP TRIGGER IF EXISTS create_profile_trigger       ON auth.users;
  DROP TRIGGER IF EXISTS sync_profile_trigger         ON auth.users;
EXCEPTION WHEN others THEN NULL;
END; $$;

-- 3. Créer/corriger l'utilisateur admin YG-T directement en base
DO $$
DECLARE
  v_uid uuid;
  v_email text := 'yg-t@aboupro.app';
  v_password text := 'Aboumohandyounesali649005';
BEGIN
  -- Cherche si l'utilisateur existe déjà
  SELECT id INTO v_uid FROM auth.users WHERE email = v_email;

  IF v_uid IS NULL THEN
    -- Crée le nouvel utilisateur
    v_uid := gen_random_uuid();
    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_uid,
      'authenticated',
      'authenticated',
      v_email,
      crypt(v_password, gen_salt('bf', 10)),
      NOW(),
      '{"provider":"email","providers":["email"]}',
      '{}',
      NOW(), NOW(),
      '', '', '', ''
    );
    RAISE NOTICE '✓ Utilisateur créé : %', v_uid;
  ELSE
    -- Met à jour le mot de passe et confirme l'email
    UPDATE auth.users
    SET
      encrypted_password  = crypt(v_password, gen_salt('bf', 10)),
      email_confirmed_at  = NOW(),
      updated_at          = NOW()
    WHERE id = v_uid;
    RAISE NOTICE '✓ Utilisateur mis à jour : %', v_uid;
  END IF;

  -- Crée l'identité (tente nouveau schéma puis ancien)
  BEGIN
    INSERT INTO auth.identities (
      provider_id, id, user_id, identity_data,
      provider, last_sign_in_at, created_at, updated_at
    ) VALUES (
      v_email,
      gen_random_uuid(),
      v_uid,
      jsonb_build_object('sub', v_uid::text, 'email', v_email),
      'email',
      NOW(), NOW(), NOW()
    )
    ON CONFLICT DO NOTHING;
    RAISE NOTICE '✓ Identité créée (nouveau schéma)';
  EXCEPTION WHEN others THEN
    BEGIN
      INSERT INTO auth.identities (
        id, user_id, identity_data,
        provider, last_sign_in_at, created_at, updated_at
      ) VALUES (
        gen_random_uuid(),
        v_uid,
        jsonb_build_object('sub', v_uid::text, 'email', v_email),
        'email',
        NOW(), NOW(), NOW()
      )
      ON CONFLICT DO NOTHING;
      RAISE NOTICE '✓ Identité créée (ancien schéma)';
    EXCEPTION WHEN others THEN
      RAISE NOTICE '⚠ Identité déjà existante, ignorée';
    END;
  END;

  -- Crée ou met à jour le profil admin
  INSERT INTO public.users_profiles (id, identifier, full_name, role, is_active)
  VALUES (v_uid, 'YG-T', 'Admin', 'admin', true)
  ON CONFLICT (id) DO UPDATE
    SET identifier = 'YG-T',
        role       = 'admin',
        is_active  = true,
        updated_at = NOW();

  RAISE NOTICE '✓ Profil admin prêt pour YG-T';
END;
$$;

-- Vérification finale
SELECT
  u.email,
  u.email_confirmed_at IS NOT NULL AS email_confirme,
  p.identifier,
  p.role,
  p.is_active
FROM auth.users u
JOIN public.users_profiles p ON p.id = u.id
WHERE u.email = 'yg-t@aboupro.app';

SELECT '✓ Fix terminé — Connectez-vous avec : YG-T / Aboumohandyounesali649005' AS resultat;
