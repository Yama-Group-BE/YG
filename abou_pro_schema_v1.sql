-- ═══════════════════════════════════════════════════════════════════════
-- ABOU PRO — Schéma Supabase v1
-- Application de gestion et d'optimisation de tournées logistiques
-- Date           : 2026-06-01
-- Instructions   :
--   1. Supabase Dashboard > SQL Editor
--   2. Coller ce script et cliquer "Run"
--   3. Script idempotent : peut être relancé sans risque
--   4. Nécessite Supabase Auth activé (email/password)
--   5. Créer un bucket Storage "abou-pro-photos" (Public : non)
-- ═══════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ───────────────────────────────────────────────────────────────────────
-- FONCTIONS UTILITAIRES
-- ───────────────────────────────────────────────────────────────────────

-- Mise à jour automatique de updated_at
create or replace function aboupro_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Vérifie si l'utilisateur courant est admin
create or replace function aboupro_is_admin()
returns boolean language sql security definer stable as $$
  select exists(
    select 1 from users_profiles
    where user_id = auth.uid() and role = 'admin' and active = true
  );
$$;

-- Récupère le rôle de l'utilisateur courant
create or replace function aboupro_get_role()
returns text language sql security definer stable as $$
  select role from users_profiles
  where user_id = auth.uid() and active = true
  limit 1;
$$;


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 1 : users_profiles
-- Extension des utilisateurs auth.users avec rôle et infos métier
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists users_profiles (
  id          uuid        primary key default gen_random_uuid(),
  user_id     uuid        unique not null references auth.users(id) on delete cascade,
  name        text        not null default '',
  role        text        not null default 'chauffeur'
                          check (role in ('admin', 'chauffeur')),
  phone       text        not null default '',
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table users_profiles add column if not exists name       text        not null default '';
alter table users_profiles add column if not exists role       text        not null default 'chauffeur';
alter table users_profiles add column if not exists phone      text        not null default '';
alter table users_profiles add column if not exists active     boolean     not null default true;
alter table users_profiles add column if not exists created_at timestamptz not null default now();
alter table users_profiles add column if not exists updated_at timestamptz not null default now();

drop trigger if exists users_profiles_set_updated_at on users_profiles;
create trigger users_profiles_set_updated_at
  before update on users_profiles
  for each row execute function aboupro_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 2 : routes
-- Tournées logistiques (ensemble de stops)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists routes (
  id          uuid        primary key default gen_random_uuid(),
  name        text        not null,
  color       text        not null default '#3b82f6',
  description text        not null default '',
  created_by  uuid        references auth.users(id) on delete set null,
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table routes add column if not exists color       text        not null default '#3b82f6';
alter table routes add column if not exists description text        not null default '';
alter table routes add column if not exists created_by  uuid        references auth.users(id) on delete set null;
alter table routes add column if not exists active      boolean     not null default true;
alter table routes add column if not exists created_at  timestamptz not null default now();
alter table routes add column if not exists updated_at  timestamptz not null default now();

drop trigger if exists routes_set_updated_at on routes;
create trigger routes_set_updated_at
  before update on routes
  for each row execute function aboupro_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 3 : stops
-- Arrêts individuels dans une tournée
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists stops (
  id              uuid          primary key default gen_random_uuid(),
  route_id        uuid          not null references routes(id) on delete cascade,
  client_name     text          not null default '',
  address         text          not null default '',
  lat             double precision,
  lng             double precision,
  scheduled_time  time,
  days_active     text[]        not null default '{}',
  -- Valeurs: 'LU','MA','ME','JE','VE','SA','DI'
  operation_type  text          not null default '',
  notes           text          not null default '',
  access_code     text          not null default '',
  parking_info    text          not null default '',
  requires_photo  boolean       not null default false,
  requires_scan   boolean       not null default false,
  order_index     integer       not null default 0,
  geocoded        boolean       not null default false,
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);

alter table stops add column if not exists client_name    text          not null default '';
alter table stops add column if not exists address        text          not null default '';
alter table stops add column if not exists lat            double precision;
alter table stops add column if not exists lng            double precision;
alter table stops add column if not exists scheduled_time time;
alter table stops add column if not exists days_active    text[]        not null default '{}';
alter table stops add column if not exists operation_type text          not null default '';
alter table stops add column if not exists notes          text          not null default '';
alter table stops add column if not exists access_code    text          not null default '';
alter table stops add column if not exists parking_info   text          not null default '';
alter table stops add column if not exists requires_photo boolean       not null default false;
alter table stops add column if not exists requires_scan  boolean       not null default false;
alter table stops add column if not exists order_index    integer       not null default 0;
alter table stops add column if not exists geocoded       boolean       not null default false;
alter table stops add column if not exists created_at     timestamptz   not null default now();
alter table stops add column if not exists updated_at     timestamptz   not null default now();

drop trigger if exists stops_set_updated_at on stops;
create trigger stops_set_updated_at
  before update on stops
  for each row execute function aboupro_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 4 : assignments
-- Assignation d'une tournée à un chauffeur pour une date donnée
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists assignments (
  id            uuid        primary key default gen_random_uuid(),
  route_id      uuid        not null references routes(id) on delete restrict,
  driver_id     uuid        not null references auth.users(id) on delete restrict,
  date          date        not null,
  vehicle_type  text        not null default 'voiture'
                            check (vehicle_type in ('pied','velo','voiture','camionnette','camion')),
  status        text        not null default 'planifie'
                            check (status in ('planifie','en_cours','termine','incident')),
  start_time    time,
  end_time_max  time,
  assigned_by   uuid        references auth.users(id) on delete set null,
  notes         text        not null default '',
  started_at    timestamptz,
  finished_at   timestamptz,
  total_km      numeric(8,2),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table assignments add column if not exists vehicle_type  text        not null default 'voiture';
alter table assignments add column if not exists status        text        not null default 'planifie';
alter table assignments add column if not exists start_time    time;
alter table assignments add column if not exists end_time_max  time;
alter table assignments add column if not exists assigned_by   uuid        references auth.users(id) on delete set null;
alter table assignments add column if not exists notes         text        not null default '';
alter table assignments add column if not exists started_at    timestamptz;
alter table assignments add column if not exists finished_at   timestamptz;
alter table assignments add column if not exists total_km      numeric(8,2);
alter table assignments add column if not exists created_at    timestamptz not null default now();
alter table assignments add column if not exists updated_at    timestamptz not null default now();

drop trigger if exists assignments_set_updated_at on assignments;
create trigger assignments_set_updated_at
  before update on assignments
  for each row execute function aboupro_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 5 : assignment_stops
-- Stops spécifiques inclus dans une assignation (avec ordre personnalisé)
-- Si vide pour une assignation → tous les stops de la route sont inclus
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists assignment_stops (
  id            uuid        primary key default gen_random_uuid(),
  assignment_id uuid        not null references assignments(id) on delete cascade,
  stop_id       uuid        not null references stops(id) on delete cascade,
  order_index   integer     not null default 0,
  created_at    timestamptz not null default now(),
  unique(assignment_id, stop_id)
);

alter table assignment_stops add column if not exists order_index integer     not null default 0;
alter table assignment_stops add column if not exists created_at  timestamptz not null default now();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 6 : tour_logs
-- Journaux d'exécution par stop (arrivée, départ, problème, scan)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists tour_logs (
  id            uuid        primary key default gen_random_uuid(),
  assignment_id uuid        not null references assignments(id) on delete cascade,
  stop_id       uuid        not null references stops(id) on delete cascade,
  driver_id     uuid        not null references auth.users(id) on delete restrict,
  status        text        not null default 'pending'
                            check (status in ('pending','arrived','completed','problem','skipped')),
  arrived_at    timestamptz,
  departed_at   timestamptz,
  lat_arrival   double precision,
  lng_arrival   double precision,
  distance_to_stop numeric(8,2), -- en mètres
  issue_type    text        not null default '',
  -- Valeurs: 'sac_absent'|'acces_refuse'|'client_ferme'|'mauvaise_adresse'|'autre'
  issue_notes   text        not null default '',
  scan_code     text        not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique(assignment_id, stop_id)
);

alter table tour_logs add column if not exists status           text        not null default 'pending';
alter table tour_logs add column if not exists arrived_at       timestamptz;
alter table tour_logs add column if not exists departed_at      timestamptz;
alter table tour_logs add column if not exists lat_arrival      double precision;
alter table tour_logs add column if not exists lng_arrival      double precision;
alter table tour_logs add column if not exists distance_to_stop numeric(8,2);
alter table tour_logs add column if not exists issue_type       text        not null default '';
alter table tour_logs add column if not exists issue_notes      text        not null default '';
alter table tour_logs add column if not exists scan_code        text        not null default '';
alter table tour_logs add column if not exists created_at       timestamptz not null default now();
alter table tour_logs add column if not exists updated_at       timestamptz not null default now();

drop trigger if exists tour_logs_set_updated_at on tour_logs;
create trigger tour_logs_set_updated_at
  before update on tour_logs
  for each row execute function aboupro_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 7 : photos
-- Preuves photo liées aux stops (stockées dans Supabase Storage)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists photos (
  id            uuid        primary key default gen_random_uuid(),
  tour_log_id   uuid        references tour_logs(id) on delete cascade,
  assignment_id uuid        not null references assignments(id) on delete cascade,
  stop_id       uuid        not null references stops(id) on delete cascade,
  driver_id     uuid        not null references auth.users(id) on delete restrict,
  storage_path  text        not null,
  -- Format: {driver_id}/{date}/{assignment_id}/{stop_id}/{uuid}.jpg
  file_size     bigint,
  width         integer,
  height        integer,
  photo_type    text        not null default 'livraison',
  -- Valeurs: 'livraison'|'probleme'|'scan'
  created_at    timestamptz not null default now()
);

alter table photos add column if not exists tour_log_id   uuid        references tour_logs(id) on delete cascade;
alter table photos add column if not exists assignment_id uuid        references assignments(id) on delete cascade;
alter table photos add column if not exists storage_path  text        not null default '';
alter table photos add column if not exists file_size     bigint;
alter table photos add column if not exists width         integer;
alter table photos add column if not exists height        integer;
alter table photos add column if not exists photo_type    text        not null default 'livraison';
alter table photos add column if not exists created_at    timestamptz not null default now();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 8 : driver_positions
-- Position GPS temps réel des chauffeurs (1 ligne par chauffeur, upsert)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists driver_positions (
  id          uuid          primary key default gen_random_uuid(),
  driver_id   uuid          unique not null references auth.users(id) on delete cascade,
  lat         double precision not null,
  lng         double precision not null,
  accuracy    double precision,
  speed       double precision, -- en km/h
  heading     double precision, -- en degrés
  assignment_id uuid         references assignments(id) on delete set null,
  updated_at  timestamptz    not null default now()
);

alter table driver_positions add column if not exists lat           double precision;
alter table driver_positions add column if not exists lng           double precision;
alter table driver_positions add column if not exists accuracy      double precision;
alter table driver_positions add column if not exists speed         double precision;
alter table driver_positions add column if not exists heading       double precision;
alter table driver_positions add column if not exists assignment_id uuid         references assignments(id) on delete set null;
alter table driver_positions add column if not exists updated_at    timestamptz  not null default now();


-- ═══════════════════════════════════════════════════════════════════════
-- INDEX DE PERFORMANCE
-- ═══════════════════════════════════════════════════════════════════════

create index if not exists users_profiles_user_id_idx      on users_profiles(user_id);
create index if not exists users_profiles_role_idx         on users_profiles(role);
create index if not exists users_profiles_active_idx       on users_profiles(active) where active = true;

create index if not exists routes_active_idx               on routes(active);
create index if not exists routes_created_by_idx           on routes(created_by);

create index if not exists stops_route_id_idx              on stops(route_id);
create index if not exists stops_route_order_idx           on stops(route_id, order_index);
create index if not exists stops_geocoded_idx              on stops(geocoded) where geocoded = false;
create index if not exists stops_lat_lng_idx               on stops(lat, lng) where lat is not null;

create index if not exists assignments_driver_id_idx       on assignments(driver_id);
create index if not exists assignments_route_id_idx        on assignments(route_id);
create index if not exists assignments_date_idx            on assignments(date desc);
create index if not exists assignments_status_idx          on assignments(status);
create index if not exists assignments_driver_date_idx     on assignments(driver_id, date);

create index if not exists assignment_stops_assignment_idx on assignment_stops(assignment_id);
create index if not exists assignment_stops_stop_id_idx    on assignment_stops(stop_id);
create index if not exists assignment_stops_order_idx      on assignment_stops(assignment_id, order_index);

create index if not exists tour_logs_assignment_id_idx     on tour_logs(assignment_id);
create index if not exists tour_logs_driver_id_idx         on tour_logs(driver_id);
create index if not exists tour_logs_stop_id_idx           on tour_logs(stop_id);
create index if not exists tour_logs_status_idx            on tour_logs(status);
create index if not exists tour_logs_arrived_at_idx        on tour_logs(arrived_at desc);

create index if not exists photos_tour_log_id_idx          on photos(tour_log_id);
create index if not exists photos_driver_id_idx            on photos(driver_id);
create index if not exists photos_stop_id_idx              on photos(stop_id);
create index if not exists photos_created_at_idx           on photos(created_at desc);

create index if not exists driver_positions_driver_id_idx  on driver_positions(driver_id);
create index if not exists driver_positions_updated_at_idx on driver_positions(updated_at desc);


-- ═══════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY (RLS)
-- Admin : accès total | Chauffeur : uniquement ses propres données
-- ═══════════════════════════════════════════════════════════════════════

alter table users_profiles  enable row level security;
alter table routes           enable row level security;
alter table stops            enable row level security;
alter table assignments      enable row level security;
alter table assignment_stops enable row level security;
alter table tour_logs        enable row level security;
alter table photos           enable row level security;
alter table driver_positions enable row level security;

-- Nettoyage des policies (idempotent)
drop policy if exists "aboupro_users_profiles_admin"         on users_profiles;
drop policy if exists "aboupro_users_profiles_self_read"     on users_profiles;
drop policy if exists "aboupro_routes_admin"                 on routes;
drop policy if exists "aboupro_routes_driver_read"           on routes;
drop policy if exists "aboupro_stops_admin"                  on stops;
drop policy if exists "aboupro_stops_driver_read"            on stops;
drop policy if exists "aboupro_assignments_admin"            on assignments;
drop policy if exists "aboupro_assignments_driver_read"      on assignments;
drop policy if exists "aboupro_assignments_driver_update"    on assignments;
drop policy if exists "aboupro_assignment_stops_admin"       on assignment_stops;
drop policy if exists "aboupro_assignment_stops_driver_read" on assignment_stops;
drop policy if exists "aboupro_tour_logs_admin"              on tour_logs;
drop policy if exists "aboupro_tour_logs_driver"             on tour_logs;
drop policy if exists "aboupro_photos_admin"                 on photos;
drop policy if exists "aboupro_photos_driver"                on photos;
drop policy if exists "aboupro_driver_positions_admin_read"  on driver_positions;
drop policy if exists "aboupro_driver_positions_driver"      on driver_positions;

-- ── users_profiles ──────────────────────────────────────────────────
-- Admin : tout
create policy "aboupro_users_profiles_admin" on users_profiles
  for all
  using (aboupro_is_admin())
  with check (aboupro_is_admin());

-- Chauffeur : lire uniquement son propre profil
create policy "aboupro_users_profiles_self_read" on users_profiles
  for select
  using (user_id = auth.uid());

-- ── routes ───────────────────────────────────────────────────────────
-- Admin : tout
create policy "aboupro_routes_admin" on routes
  for all
  using (aboupro_is_admin())
  with check (aboupro_is_admin());

-- Chauffeur : lire les routes de ses assignations actives
create policy "aboupro_routes_driver_read" on routes
  for select
  using (
    active = true
    and exists(
      select 1 from assignments a
      where a.route_id = routes.id
        and a.driver_id = auth.uid()
        and a.date = current_date
    )
  );

-- ── stops ─────────────────────────────────────────────────────────────
-- Admin : tout
create policy "aboupro_stops_admin" on stops
  for all
  using (aboupro_is_admin())
  with check (aboupro_is_admin());

-- Chauffeur : lire les stops de ses assignations
create policy "aboupro_stops_driver_read" on stops
  for select
  using (
    exists(
      select 1 from assignment_stops aps
      join assignments a on a.id = aps.assignment_id
      where aps.stop_id = stops.id
        and a.driver_id = auth.uid()
        and a.date = current_date
    )
    or exists(
      select 1 from assignments a
      where a.route_id = stops.route_id
        and a.driver_id = auth.uid()
        and a.date = current_date
    )
  );

-- ── assignments ───────────────────────────────────────────────────────
-- Admin : tout
create policy "aboupro_assignments_admin" on assignments
  for all
  using (aboupro_is_admin())
  with check (aboupro_is_admin());

-- Chauffeur : lire ses propres assignations
create policy "aboupro_assignments_driver_read" on assignments
  for select
  using (driver_id = auth.uid());

-- Chauffeur : mettre à jour le statut de ses propres assignations
create policy "aboupro_assignments_driver_update" on assignments
  for update
  using (driver_id = auth.uid())
  with check (driver_id = auth.uid());

-- ── assignment_stops ──────────────────────────────────────────────────
-- Admin : tout
create policy "aboupro_assignment_stops_admin" on assignment_stops
  for all
  using (aboupro_is_admin())
  with check (aboupro_is_admin());

-- Chauffeur : lire les stops de ses assignations
create policy "aboupro_assignment_stops_driver_read" on assignment_stops
  for select
  using (
    exists(
      select 1 from assignments a
      where a.id = assignment_stops.assignment_id
        and a.driver_id = auth.uid()
    )
  );

-- ── tour_logs ─────────────────────────────────────────────────────────
-- Admin : tout
create policy "aboupro_tour_logs_admin" on tour_logs
  for all
  using (aboupro_is_admin())
  with check (aboupro_is_admin());

-- Chauffeur : lire et modifier uniquement ses propres logs
create policy "aboupro_tour_logs_driver" on tour_logs
  for all
  using (driver_id = auth.uid())
  with check (driver_id = auth.uid());

-- ── photos ────────────────────────────────────────────────────────────
-- Admin : tout
create policy "aboupro_photos_admin" on photos
  for all
  using (aboupro_is_admin())
  with check (aboupro_is_admin());

-- Chauffeur : lire et uploader uniquement ses propres photos
create policy "aboupro_photos_driver" on photos
  for all
  using (driver_id = auth.uid())
  with check (driver_id = auth.uid());

-- ── driver_positions ──────────────────────────────────────────────────
-- Admin : lire toutes les positions
create policy "aboupro_driver_positions_admin_read" on driver_positions
  for select
  using (aboupro_is_admin());

-- Chauffeur : lire et mettre à jour uniquement sa propre position
create policy "aboupro_driver_positions_driver" on driver_positions
  for all
  using (driver_id = auth.uid())
  with check (driver_id = auth.uid());


-- ═══════════════════════════════════════════════════════════════════════
-- SUPABASE STORAGE — Bucket photos (à créer manuellement dans le dashboard)
-- ═══════════════════════════════════════════════════════════════════════
-- 1. Dashboard > Storage > New Bucket
-- 2. Nom : "abou-pro-photos"
-- 3. Public : NON (accès contrôlé via policies)
-- 4. File size limit : 5MB
-- 5. Allowed MIME types : image/jpeg, image/png, image/webp

-- Storage policy (à appliquer dans le dashboard Storage > Policies) :
-- INSERT : (bucket_id = 'abou-pro-photos' AND auth.uid()::text = (storage.foldername(name))[1])
-- SELECT : (bucket_id = 'abou-pro-photos' AND auth.uid()::text = (storage.foldername(name))[1])
--          OR aboupro_is_admin()


-- ═══════════════════════════════════════════════════════════════════════
-- REALTIME — Activer les publications en temps réel
-- ═══════════════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  foreach t in array array[
    'users_profiles','routes','stops','assignments',
    'assignment_stops','tour_logs','photos','driver_positions'
  ]
  loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception when duplicate_object then
      null; -- déjà ajouté, ignorer
    end;
  end loop;
end $$;


-- ═══════════════════════════════════════════════════════════════════════
-- VUES UTILITAIRES (admin uniquement — pour analytics et reporting)
-- ═══════════════════════════════════════════════════════════════════════

-- Vue 1 : Assignations enrichies avec infos chauffeur et tournée
create or replace view aboupro_assignments_view as
select
  a.id,
  a.date,
  a.status,
  a.vehicle_type,
  a.start_time,
  a.end_time_max,
  a.started_at,
  a.finished_at,
  a.total_km,
  a.notes,
  a.created_at,
  r.id        as route_id,
  r.name      as route_name,
  r.color     as route_color,
  up.name     as driver_name,
  up.phone    as driver_phone,
  up.user_id  as driver_user_id,
  (select count(*) from assignment_stops aps where aps.assignment_id = a.id) as total_stops,
  (select count(*) from tour_logs tl
   where tl.assignment_id = a.id and tl.status = 'completed') as completed_stops,
  (select count(*) from tour_logs tl
   where tl.assignment_id = a.id and tl.status = 'problem') as problem_stops
from assignments a
join routes r on r.id = a.route_id
join users_profiles up on up.user_id = a.driver_id;

-- Vue 2 : KPIs chauffeur (ponctualité, volume)
create or replace view aboupro_driver_kpis as
select
  up.user_id,
  up.name        as driver_name,
  count(distinct a.id)           as total_assignments,
  count(distinct case when a.status = 'termine' then a.id end) as completed_assignments,
  count(tl.id)                   as total_stops_done,
  count(case when tl.status = 'completed' then 1 end) as successful_stops,
  count(case when tl.status = 'problem'   then 1 end) as problem_stops,
  round(
    100.0 * count(case when tl.status = 'completed' then 1 end)
    / nullif(count(tl.id), 0), 1
  )                              as success_rate,
  max(a.date)                    as last_assignment_date
from users_profiles up
join assignments a on a.driver_id = up.user_id
left join tour_logs tl on tl.assignment_id = a.id
where up.role = 'chauffeur'
group by up.user_id, up.name;

-- Vue 3 : Stops avec statut courant pour le dashboard admin
create or replace view aboupro_stops_status_view as
select
  s.id,
  s.route_id,
  s.client_name,
  s.address,
  s.lat,
  s.lng,
  s.scheduled_time,
  s.order_index,
  s.requires_photo,
  s.requires_scan,
  r.name      as route_name,
  r.color     as route_color,
  tl.status   as log_status,
  tl.arrived_at,
  tl.issue_type,
  up.name     as driver_name,
  a.date      as assignment_date
from stops s
join routes r on r.id = s.route_id
left join assignment_stops aps on aps.stop_id = s.id
left join assignments a on a.id = aps.assignment_id and a.date = current_date
left join tour_logs tl on tl.stop_id = s.id and tl.assignment_id = a.id
left join users_profiles up on up.user_id = a.driver_id;


-- ═══════════════════════════════════════════════════════════════════════
-- DONNÉES INITIALES — Créer l'utilisateur admin après inscription
-- ═══════════════════════════════════════════════════════════════════════
-- Après inscription manuelle dans Supabase Auth (Dashboard > Authentication > Users),
-- insérer le profil admin :
--
-- insert into users_profiles (user_id, name, role, phone, active)
-- values (
--   '<uuid-de-ton-compte-auth>',
--   'Admin ABOU PRO',
--   'admin',
--   '+32 XXX XX XX XX',
--   true
-- );


-- ═══════════════════════════════════════════════════════════════════════
-- VÉRIFICATION FINALE
-- ═══════════════════════════════════════════════════════════════════════
select
  t.table_name,
  pg_size_pretty(pg_total_relation_size(quote_ident(t.table_name))) as taille,
  (select count(*) from information_schema.columns c
   where c.table_name = t.table_name and c.table_schema = 'public') as nb_colonnes,
  obj_description(to_regclass(t.table_name)::oid, 'pg_class') as commentaire
from information_schema.tables t
where t.table_schema = 'public'
  and t.table_name in (
    'users_profiles','routes','stops','assignments',
    'assignment_stops','tour_logs','photos','driver_positions'
  )
order by t.table_name;
