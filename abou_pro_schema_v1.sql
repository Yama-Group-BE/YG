-- ═══════════════════════════════════════════════════════════════════════
-- ABOU PRO — Schéma Supabase complet (copier-coller direct)
-- Application de gestion et d'optimisation de tournées logistiques
-- ───────────────────────────────────────────────────────────────────────
-- MODE D'EMPLOI :
--   1. Supabase Dashboard > SQL Editor > New query
--   2. Coller TOUT ce script
--   3. Cliquer "Run"  →  doit afficher "Success" + la liste des 8 tables
--   4. Script idempotent : relançable sans risque
-- ═══════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ───────────────────────────────────────────────────────────────────────
-- FONCTIONS UTILITAIRES (créées en premier — utilisées par triggers + RLS)
-- ───────────────────────────────────────────────────────────────────────
create or replace function aboupro_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- security definer = contourne RLS → évite la récursion infinie dans les policies
create or replace function aboupro_is_admin()
returns boolean
language sql security definer stable
set search_path = public as $$
  select exists(
    select 1 from public.users_profiles
    where user_id = auth.uid() and role = 'admin' and active = true
  );
$$;


-- ═══════════════════════════════════════════════════════════════════════
-- TABLES (créées dans l'ordre des dépendances)
-- ═══════════════════════════════════════════════════════════════════════

-- 1) users_profiles ──────────────────────────────────────────────────────
create table if not exists users_profiles (
  id          uuid        primary key default gen_random_uuid(),
  user_id     uuid        unique not null references auth.users(id) on delete cascade,
  name        text        not null default '',
  role        text        not null default 'chauffeur' check (role in ('admin','chauffeur')),
  phone       text        not null default '',
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 2) routes ───────────────────────────────────────────────────────────────
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

-- 3) stops ────────────────────────────────────────────────────────────────
create table if not exists stops (
  id              uuid        primary key default gen_random_uuid(),
  route_id        uuid        not null references routes(id) on delete cascade,
  client_name     text        not null default '',
  address         text        not null default '',
  lat             double precision,
  lng             double precision,
  scheduled_time  time,
  days_active     text[]      not null default array[]::text[],  -- 'LU','MA','ME','JE','VE','SA','DI'
  operation_type  text        not null default '',
  notes           text        not null default '',
  access_code     text        not null default '',
  parking_info    text        not null default '',
  requires_photo  boolean     not null default false,
  requires_scan   boolean     not null default false,
  order_index     integer     not null default 0,
  geocoded        boolean     not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- 4) assignments ──────────────────────────────────────────────────────────
create table if not exists assignments (
  id            uuid        primary key default gen_random_uuid(),
  route_id      uuid        not null references routes(id) on delete restrict,
  driver_id     uuid        not null references auth.users(id) on delete restrict,
  date          date        not null,
  vehicle_type  text        not null default 'voiture' check (vehicle_type in ('pied','velo','voiture','camionnette','camion')),
  status        text        not null default 'planifie' check (status in ('planifie','en_cours','termine','incident')),
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

-- 5) assignment_stops ─────────────────────────────────────────────────────
create table if not exists assignment_stops (
  id            uuid        primary key default gen_random_uuid(),
  assignment_id uuid        not null references assignments(id) on delete cascade,
  stop_id       uuid        not null references stops(id) on delete cascade,
  order_index   integer     not null default 0,
  created_at    timestamptz not null default now(),
  unique(assignment_id, stop_id)
);

-- 6) tour_logs ────────────────────────────────────────────────────────────
create table if not exists tour_logs (
  id               uuid        primary key default gen_random_uuid(),
  assignment_id    uuid        not null references assignments(id) on delete cascade,
  stop_id          uuid        not null references stops(id) on delete cascade,
  driver_id        uuid        not null references auth.users(id) on delete restrict,
  status           text        not null default 'pending' check (status in ('pending','arrived','completed','problem','skipped')),
  arrived_at       timestamptz,
  departed_at      timestamptz,
  lat_arrival      double precision,
  lng_arrival      double precision,
  distance_to_stop numeric(8,2),                 -- en mètres
  issue_type       text        not null default '', -- sac_absent|acces_refuse|client_ferme|mauvaise_adresse|autre
  issue_notes      text        not null default '',
  scan_code        text        not null default '',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique(assignment_id, stop_id)
);

-- 7) photos ───────────────────────────────────────────────────────────────
create table if not exists photos (
  id            uuid        primary key default gen_random_uuid(),
  tour_log_id   uuid        references tour_logs(id) on delete cascade,
  assignment_id uuid        references assignments(id) on delete cascade,
  stop_id       uuid        not null references stops(id) on delete cascade,
  driver_id     uuid        not null references auth.users(id) on delete restrict,
  storage_path  text        not null,            -- {driver_id}/{date}/{assignment_id}/{stop_id}/{uuid}.jpg
  file_size     bigint,
  width         integer,
  height        integer,
  photo_type    text        not null default 'livraison', -- livraison|probleme|scan
  created_at    timestamptz not null default now()
);

-- 8) driver_positions ─────────────────────────────────────────────────────
create table if not exists driver_positions (
  id            uuid             primary key default gen_random_uuid(),
  driver_id     uuid             unique not null references auth.users(id) on delete cascade,
  lat           double precision not null,
  lng           double precision not null,
  accuracy      double precision,
  speed         double precision,
  heading       double precision,
  assignment_id uuid             references assignments(id) on delete set null,
  updated_at    timestamptz      not null default now()
);


-- ═══════════════════════════════════════════════════════════════════════
-- TRIGGERS updated_at
-- ═══════════════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  foreach t in array array[
    'users_profiles','routes','stops','assignments','tour_logs'
  ]
  loop
    execute format('drop trigger if exists %I_set_updated_at on %I', t, t);
    execute format(
      'create trigger %I_set_updated_at before update on %I
       for each row execute function aboupro_set_updated_at()', t, t);
  end loop;
end $$;


-- ═══════════════════════════════════════════════════════════════════════
-- INDEX DE PERFORMANCE
-- ═══════════════════════════════════════════════════════════════════════
create index if not exists users_profiles_user_id_idx      on users_profiles(user_id);
create index if not exists users_profiles_role_idx         on users_profiles(role);

create index if not exists routes_active_idx               on routes(active);

create index if not exists stops_route_id_idx              on stops(route_id);
create index if not exists stops_route_order_idx           on stops(route_id, order_index);
create index if not exists stops_geocoded_idx              on stops(geocoded) where geocoded = false;

create index if not exists assignments_driver_id_idx       on assignments(driver_id);
create index if not exists assignments_route_id_idx        on assignments(route_id);
create index if not exists assignments_date_idx            on assignments(date desc);
create index if not exists assignments_driver_date_idx     on assignments(driver_id, date);

create index if not exists assignment_stops_assignment_idx on assignment_stops(assignment_id);
create index if not exists assignment_stops_stop_id_idx    on assignment_stops(stop_id);

create index if not exists tour_logs_assignment_id_idx     on tour_logs(assignment_id);
create index if not exists tour_logs_driver_id_idx         on tour_logs(driver_id);
create index if not exists tour_logs_status_idx            on tour_logs(status);

create index if not exists photos_stop_id_idx              on photos(stop_id);
create index if not exists photos_driver_id_idx            on photos(driver_id);

create index if not exists driver_positions_driver_id_idx  on driver_positions(driver_id);


-- ═══════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY — admin = tout | chauffeur = uniquement ses données
-- ═══════════════════════════════════════════════════════════════════════
alter table users_profiles  enable row level security;
alter table routes           enable row level security;
alter table stops            enable row level security;
alter table assignments      enable row level security;
alter table assignment_stops enable row level security;
alter table tour_logs        enable row level security;
alter table photos           enable row level security;
alter table driver_positions enable row level security;

-- Nettoyage idempotent
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

-- users_profiles
create policy "aboupro_users_profiles_admin" on users_profiles
  for all using (aboupro_is_admin()) with check (aboupro_is_admin());
create policy "aboupro_users_profiles_self_read" on users_profiles
  for select using (user_id = auth.uid());

-- routes
create policy "aboupro_routes_admin" on routes
  for all using (aboupro_is_admin()) with check (aboupro_is_admin());
create policy "aboupro_routes_driver_read" on routes
  for select using (
    active = true
    and exists(select 1 from assignments a
               where a.route_id = routes.id and a.driver_id = auth.uid()
                 and a.date = current_date)
  );

-- stops
create policy "aboupro_stops_admin" on stops
  for all using (aboupro_is_admin()) with check (aboupro_is_admin());
create policy "aboupro_stops_driver_read" on stops
  for select using (
    exists(select 1 from assignments a
           where a.route_id = stops.route_id and a.driver_id = auth.uid()
             and a.date = current_date)
    or exists(select 1 from assignment_stops aps
              join assignments a on a.id = aps.assignment_id
              where aps.stop_id = stops.id and a.driver_id = auth.uid()
                and a.date = current_date)
  );

-- assignments
create policy "aboupro_assignments_admin" on assignments
  for all using (aboupro_is_admin()) with check (aboupro_is_admin());
create policy "aboupro_assignments_driver_read" on assignments
  for select using (driver_id = auth.uid());
create policy "aboupro_assignments_driver_update" on assignments
  for update using (driver_id = auth.uid()) with check (driver_id = auth.uid());

-- assignment_stops
create policy "aboupro_assignment_stops_admin" on assignment_stops
  for all using (aboupro_is_admin()) with check (aboupro_is_admin());
create policy "aboupro_assignment_stops_driver_read" on assignment_stops
  for select using (
    exists(select 1 from assignments a
           where a.id = assignment_stops.assignment_id and a.driver_id = auth.uid())
  );

-- tour_logs
create policy "aboupro_tour_logs_admin" on tour_logs
  for all using (aboupro_is_admin()) with check (aboupro_is_admin());
create policy "aboupro_tour_logs_driver" on tour_logs
  for all using (driver_id = auth.uid()) with check (driver_id = auth.uid());

-- photos
create policy "aboupro_photos_admin" on photos
  for all using (aboupro_is_admin()) with check (aboupro_is_admin());
create policy "aboupro_photos_driver" on photos
  for all using (driver_id = auth.uid()) with check (driver_id = auth.uid());

-- driver_positions
create policy "aboupro_driver_positions_admin_read" on driver_positions
  for select using (aboupro_is_admin());
create policy "aboupro_driver_positions_driver" on driver_positions
  for all using (driver_id = auth.uid()) with check (driver_id = auth.uid());


-- ═══════════════════════════════════════════════════════════════════════
-- REALTIME — durci : crée la publication si absente, ajoute sans doublon
-- ═══════════════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array[
    'users_profiles','routes','stops','assignments',
    'assignment_stops','tour_logs','photos','driver_positions'
  ]
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;


-- ═══════════════════════════════════════════════════════════════════════
-- VUES ANALYTIQUES (Module 9)
-- ═══════════════════════════════════════════════════════════════════════
create or replace view aboupro_assignments_view as
select
  a.id, a.date, a.status, a.vehicle_type, a.start_time, a.end_time_max,
  a.started_at, a.finished_at, a.total_km, a.notes, a.created_at,
  r.id as route_id, r.name as route_name, r.color as route_color,
  up.name as driver_name, up.phone as driver_phone, up.user_id as driver_user_id,
  (select count(*) from assignment_stops aps where aps.assignment_id = a.id) as total_stops,
  (select count(*) from tour_logs tl where tl.assignment_id = a.id and tl.status = 'completed') as completed_stops,
  (select count(*) from tour_logs tl where tl.assignment_id = a.id and tl.status = 'problem')   as problem_stops
from assignments a
join routes r on r.id = a.route_id
join users_profiles up on up.user_id = a.driver_id;

create or replace view aboupro_driver_kpis as
select
  up.user_id, up.name as driver_name,
  count(distinct a.id) as total_assignments,
  count(distinct case when a.status = 'termine' then a.id end) as completed_assignments,
  count(tl.id) as total_stops_done,
  count(case when tl.status = 'completed' then 1 end) as successful_stops,
  count(case when tl.status = 'problem'   then 1 end) as problem_stops,
  round(100.0 * count(case when tl.status = 'completed' then 1 end)
        / nullif(count(tl.id), 0), 1) as success_rate,
  max(a.date) as last_assignment_date
from users_profiles up
join assignments a on a.driver_id = up.user_id
left join tour_logs tl on tl.assignment_id = a.id
where up.role = 'chauffeur'
group by up.user_id, up.name;


-- ═══════════════════════════════════════════════════════════════════════
-- APRÈS LE RUN — créer ton compte admin :
--   1. Dashboard > Authentication > Users > Add user (email + mot de passe)
--   2. Copier l'UID du user créé
--   3. Lancer (en remplaçant l'UID) :
--        insert into users_profiles (user_id, name, role, active)
--        values ('<UID>', 'Admin ABOU PRO', 'admin', true);
-- Storage : créer le bucket "abou-pro-photos" (non public, 5MB, image/*)
-- ═══════════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════════
-- VÉRIFICATION — doit lister les 8 tables
-- ═══════════════════════════════════════════════════════════════════════
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in (
    'users_profiles','routes','stops','assignments',
    'assignment_stops','tour_logs','photos','driver_positions'
  )
order by table_name;
