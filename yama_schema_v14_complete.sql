-- ═══════════════════════════════════════════════════════════════════════════
-- YAMA GROUP — Schéma Supabase COMPLET v14
-- Généré le : 2026-05-30
-- Source     : yama_platform.html (analyse complète de toutes les lignes de code)
-- Mode       : Migration ADDITIVE et idempotente — sûr sur base existante
-- ═══════════════════════════════════════════════════════════════════════════
-- ORDRE D'EXÉCUTION :
--   1. Extensions & types ENUM
--   2. Tables (CREATE TABLE IF NOT EXISTS)
--   3. Colonnes additionnelles (ALTER TABLE … IF NOT EXISTS)
--   4. Index
--   5. Row-Level Security
--   6. Triggers (updated_at automatique)
--   7. Fonctions utilitaires
--   8. Vues métier
--   9. Table de référence (documentation)
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 0. EXTENSIONS
-- ───────────────────────────────────────────────────────────────────────────
create extension if not exists "uuid-ossp";
create extension if not exists "pg_trgm";     -- recherche texte full-text sur nom/adresse

-- ───────────────────────────────────────────────────────────────────────────
-- 1. TYPES ENUM (immuables côté JS — ne pas modifier sans migration)
-- ───────────────────────────────────────────────────────────────────────────

do $$ begin
  create type yama_devis_status_enum  as enum ('pending','accepted','refused','done','invoiced');
  exception when duplicate_object then null;
end $$;

do $$ begin
  create type yama_doc_type_enum      as enum ('devis','facture','devis-brouillon');
  exception when duplicate_object then null;
end $$;

do $$ begin
  create type yama_contact_type_enum  as enum ('devis','chantier','contact','recontact');
  exception when duplicate_object then null;
end $$;

do $$ begin
  create type yama_pipeline_stage_enum as enum (
    'contact','rdv','recontact','devis','waiting','chantier','fini','refused'
  );
  exception when duplicate_object then null;
end $$;

do $$ begin
  create type yama_age_batiment_enum  as enum ('moins10','plus10','inconnu');
  exception when duplicate_object then null;
end $$;

-- ───────────────────────────────────────────────────────────────────────────
-- 2. TABLE : yama_crm
-- Contacts CRM — source : localStorage yama_crm_v2
-- Colonnes "data" = objet JSON complet (pour compatibilité JS localStorage)
-- Colonnes dénormalisées = champs critiques pour requêtes SQL rapides
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_crm (
  -- ── Clés ──
  id              bigint        generated always as identity primary key,
  contact_id      text          not null unique,           -- UUID généré côté JS

  -- ── Données brutes (objet JS sérialisé — source de vérité localStorage) ──
  data            jsonb         not null default '{}',

  -- ── Champs dénormalisés pour requêtes rapides ──
  -- Contact de base
  nom             text          generated always as (data->>'nom') stored,
  civilite        text          generated always as (data->>'civilite') stored,
  tel             text          generated always as (data->>'tel') stored,
  email           text          generated always as (data->>'email') stored,
  adresse         text          generated always as (data->>'adresse') stored,
  commune         text          generated always as (data->>'commune') stored,

  -- Pipeline
  type_contact    text          generated always as (coalesce(data->>'type','devis')) stored,
  follow_up_status text         generated always as (data->>'followUpStatus') stored,
  status          text          generated always as (data->>'status') stored,

  -- Flags booléens dénormalisés
  waiting_response boolean      generated always as (
                                  coalesce((data->>'waitingResponse')::boolean, false)
                                ) stored,
  devis_refused   boolean       generated always as (
                                  coalesce((data->>'devisRefused')::boolean, false)
                                ) stored,
  finished        boolean       generated always as (
                                  coalesce((data->>'finished')::boolean, false)
                                ) stored,
  deleted         boolean       generated always as (
                                  coalesce((data->>'deleted')::boolean, false)
                                ) stored,

  -- Liaison devis
  devis_doc_num   text          generated always as (data->>'devisDocNum') stored,

  -- Source/origine
  source_client   text          generated always as (data->>'sourceClient') stored,

  -- Sous-traitant attribué
  sous_traitant   text          generated always as (data->>'st') stored,

  -- RDV
  rdv_date        date          generated always as (
                                  case when (data->>'date') ~ '^\d{4}-\d{2}-\d{2}$'
                                       then (data->>'date')::date else null end
                                ) stored,
  rdv_heure       text          generated always as (data->>'heure') stored,

  -- ── Colonnes horodatage (non dans "data" — écrites directement) ──
  waiting_response_at   timestamptz,
  chantier_confirmed_at timestamptz,
  devis_refused_at      timestamptz,
  follow_up_done_at     timestamptz,
  gcal_added_at         timestamptz,

  -- ── Timestamps système ──
  saved_at        timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 3. TABLE : yama_history
-- Devis et factures — source : localStorage yama_history_v3
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_history (
  -- ── Clés ──
  id              bigint        generated always as identity primary key,
  doc_num         text          not null unique,           -- ex: YG-26-101 / FYG-26-001

  -- ── Données brutes ──
  data            jsonb         not null default '{}',

  -- ── Champs dénormalisés ──
  doc_type        text          generated always as (coalesce(data->>'docType','devis')) stored,
  client_nom      text          generated always as (data->>'clientNom') stored,
  client_tel      text          generated always as (data->>'clientTel') stored,
  client_email    text          generated always as (data->>'clientEmail') stored,
  client_adresse  text          generated always as (data->>'clientAdresse') stored,
  client_cp       text          generated always as (data->>'clientCP') stored,
  client_ville    text          generated always as (data->>'clientVille') stored,

  -- Chantier (peut différer du client)
  chantier_ref    text          generated always as (data->>'chantierRef') stored,
  chantier_adresse text         generated always as (data->>'chantierAdresse') stored,
  chantier_cp     text          generated always as (data->>'chantierCP') stored,
  chantier_ville  text          generated always as (data->>'chantierVille') stored,

  -- Age bâtiment (détermine TVA 6% ou 21%)
  age_batiment    text          generated always as (data->>'ageBatiment') stored,

  -- Totaux financiers
  total_ht        numeric(12,2) generated always as (
                                  case when (data->>'totalHT') ~ '^-?\d+(\.\d+)?$'
                                       then (data->>'totalHT')::numeric else null end
                                ) stored,
  total_tva       numeric(12,2) generated always as (
                                  case when (data->>'totalTVA') ~ '^-?\d+(\.\d+)?$'
                                       then (data->>'totalTVA')::numeric else null end
                                ) stored,
  total_ttc       numeric(12,2) generated always as (
                                  case when (data->>'totalTTC') ~ '^-?\d+(\.\d+)?$'
                                       then (data->>'totalTTC')::numeric else null end
                                ) stored,
  remise_eur      numeric(10,2) generated always as (
                                  case when (data->>'remiseEur') ~ '^-?\d+(\.\d+)?$'
                                       then (data->>'remiseEur')::numeric else null end
                                ) stored,
  remise_pct      numeric(5,2)  generated always as (
                                  case when (data->>'remisePct') ~ '^-?\d+(\.\d+)?$'
                                       then (data->>'remisePct')::numeric else null end
                                ) stored,
  cout_materiaux  numeric(10,2) generated always as (
                                  case when (data->>'coutMateriaux') ~ '^-?\d+(\.\d+)?$'
                                       then (data->>'coutMateriaux')::numeric else null end
                                ) stored,
  autres_couts    numeric(10,2) generated always as (
                                  case when (data->>'autresCouts') ~ '^-?\d+(\.\d+)?$'
                                       then (data->>'autresCouts')::numeric else null end
                                ) stored,

  -- Sous-traitant principal sur ce document
  st_nom          text          generated always as (data->>'stNom') stored,

  -- Tombstone : document supprimé côté JS
  deleted         boolean       generated always as (
                                  coalesce((data->>'deleted')::boolean, false)
                                ) stored,
  deleted_at      timestamptz   generated always as (
                                  case when (data->>'deletedAt') ~ '^\d{4}-'
                                       then (data->>'deletedAt')::timestamptz else null end
                                ) stored,

  -- PDF archivé (données de base — détail dans yama_pdf_documents)
  pdf_stored      boolean       generated always as (
                                  coalesce((data->>'pdfStored')::boolean, false)
                                ) stored,
  pdf_file_name   text          generated always as (data->>'pdfFileName') stored,

  -- ── Timestamps système ──
  saved_at        timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 4. TABLE : yama_devis_status
-- Statut commercial de chaque devis — source : localStorage yama_devis_status_v1
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_devis_status (
  doc_num         text          not null primary key,      -- FK → yama_history.doc_num
  status          text          not null default 'pending'
                                check (status in ('pending','accepted','refused','done','invoiced')),
  note            text          not null default '',
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 5. TABLE : yama_pdf_documents
-- Archivage des PDFs générés (base64) — source : syncPushPdfDocument()
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_pdf_documents (
  id              bigint        generated always as identity primary key,
  doc_num         text          not null unique,           -- FK → yama_history.doc_num
  doc_type        text          not null default 'devis'
                                check (doc_type in ('devis','facture','devis-brouillon')),
  file_name       text          not null,
  mime_type       text          not null default 'application/pdf',
  data_url        text          not null,                  -- base64 data URL complet
  size_bytes      bigint,
  saved_at        timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 6. TABLE : yama_st_paid
-- Suivi paiements sous-traitants par devis/facture
-- Source : localStorage yama_st_paid_v1 — structure { doc_num: { paid, amount, paid_at, note } }
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_st_paid (
  doc_num         text          not null primary key,      -- FK → yama_history.doc_num
  paid            boolean       not null default false,
  amount          numeric(10,2),                           -- montant réellement payé au ST
  paid_at         timestamptz,
  note            text          not null default '',
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 7. TABLE : yama_client_paid
-- Suivi paiements clients par facture
-- Source : localStorage yama_client_paid_v1
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_client_paid (
  doc_num         text          not null primary key,      -- FK → yama_history.doc_num
  paid            boolean       not null default false,
  amount          numeric(10,2),                           -- montant encaissé
  paid_at         timestamptz,
  payment_method  text,                                    -- virement, espèces, chèque…
  note            text          not null default '',
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 8. TABLE : yama_sous_traitants   (alias: yama_soustraitants dans certains contextes)
-- Carnet des sous-traitants — source : localStorage yama_soustraitants_v1
-- Nom canonique depuis v12 : yama_sous_traitants (avec underscore)
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_sous_traitants (
  id              bigint        generated always as identity primary key,
  nom             text          not null unique,
  tel             text          not null default '',
  spec            text          not null default '',       -- spécialité / métier
  tarif           numeric(10,2),                           -- tarif horaire indicatif
  source          text          not null default 'crm',    -- 'crm' | 'platform'
  updated_at      timestamptz   not null default now()
);

-- Alias pour compatibilité avec l'écriture compacte (yama_soustraitants)
-- Créé seulement si yama_soustraitants n'existe pas encore
do $$
begin
  if not exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'yama_soustraitants'
  ) then
    execute 'create view yama_soustraitants as select * from yama_sous_traitants';
  end if;
end $$;

-- ───────────────────────────────────────────────────────────────────────────
-- 9. TABLE : yama_counters
-- Numérotation devis/factures + timestamps de synchro
-- Source : syncCounters() — clés : 'devis', 'facture', 'st_updated_at'
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_counters (
  id              text          not null primary key,      -- 'devis' | 'facture' | 'st_updated_at'
  value           bigint        not null default 0,        -- valeur numérique courante
  ts              timestamptz   not null default now()     -- horodatage de la dernière mise à jour
);

-- Valeurs initiales (idempotent)
insert into yama_counters (id, value, ts) values
  ('devis',          101, now()),
  ('facture',          1, now()),
  ('st_updated_at',    0, now())
on conflict (id) do nothing;

-- ───────────────────────────────────────────────────────────────────────────
-- 10. TABLE : yama_settings
-- Paramètres de l'application — source : getSetting() / setSetting()
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_settings (
  key             text          not null primary key,
  value           jsonb         not null default 'null',
  updated_at      timestamptz   not null default now()
);

-- Paramètres par défaut du calculateur YAMA
insert into yama_settings (key, value) values
  ('financier.acomptePct',       '30'),
  ('financier.devisPolicyFee',   '150'),
  ('financier.tvaDefault',       '"0.06"'),
  ('marges.tiers', '[
    {"min":0,    "max":500,   "rec":40, "label":"0–500€"},
    {"min":500,  "max":1000,  "rec":38, "label":"500€–1k"},
    {"min":1000, "max":2000,  "rec":35, "label":"1k–2k"},
    {"min":2000, "max":5000,  "rec":30, "label":"2k–5k"},
    {"min":5000, "max":10000, "rec":25, "label":"5k–10k"},
    {"min":10000,"max":null,  "rec":20, "label":">10k"}
  ]'),
  ('entreprise.nom',    '"YAMA Group"'),
  ('entreprise.tel',    '"0489 33 77 00"'),
  ('entreprise.email',  '"info@yama-group.be"'),
  ('entreprise.tva',    '"BE0XXX.XXX.XXX"'),
  ('entreprise.iban',   '"BE00 0000 0000 0000"'),
  ('gcal.clientId',     '""')
on conflict (key) do nothing;

-- ───────────────────────────────────────────────────────────────────────────
-- 11. COLONNES ADDITIONNELLES (migration additive — idempotent)
-- ───────────────────────────────────────────────────────────────────────────

-- yama_crm : colonnes optionnelles pas encore créées dans v12/v13
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='waiting_response_at') then
    alter table yama_crm add column waiting_response_at timestamptz;
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='chantier_confirmed_at') then
    alter table yama_crm add column chantier_confirmed_at timestamptz;
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='devis_refused_at') then
    alter table yama_crm add column devis_refused_at timestamptz;
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='follow_up_done_at') then
    alter table yama_crm add column follow_up_done_at timestamptz;
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='gcal_added_at') then
    alter table yama_crm add column gcal_added_at timestamptz;
  end if;
end $$;

-- yama_st_paid : colonnes amount et note ajoutées si absentes
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_st_paid' and column_name='amount') then
    alter table yama_st_paid add column amount numeric(10,2);
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_st_paid' and column_name='note') then
    alter table yama_st_paid add column note text not null default '';
  end if;
end $$;

-- yama_client_paid : colonnes amount, payment_method, note ajoutées si absentes
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_client_paid' and column_name='amount') then
    alter table yama_client_paid add column amount numeric(10,2);
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_client_paid' and column_name='payment_method') then
    alter table yama_client_paid add column payment_method text;
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_client_paid' and column_name='note') then
    alter table yama_client_paid add column note text not null default '';
  end if;
end $$;

-- yama_sous_traitants : colonnes spec, tarif, source si absentes
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_sous_traitants' and column_name='spec') then
    alter table yama_sous_traitants add column spec text not null default '';
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_sous_traitants' and column_name='tarif') then
    alter table yama_sous_traitants add column tarif numeric(10,2);
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_sous_traitants' and column_name='source') then
    alter table yama_sous_traitants add column source text not null default 'crm';
  end if;
end $$;

-- ───────────────────────────────────────────────────────────────────────────
-- 12. INDEX
-- ───────────────────────────────────────────────────────────────────────────

-- yama_crm
create index if not exists idx_yama_crm_contact_id
  on yama_crm (contact_id);

create index if not exists idx_yama_crm_tel
  on yama_crm (tel)
  where tel is not null and deleted = false;

create index if not exists idx_yama_crm_follow_up_status
  on yama_crm (follow_up_status)
  where deleted = false;

create index if not exists idx_yama_crm_devis_doc_num
  on yama_crm (devis_doc_num)
  where devis_doc_num is not null;

create index if not exists idx_yama_crm_rdv_date
  on yama_crm (rdv_date)
  where rdv_date is not null and deleted = false;

create index if not exists idx_yama_crm_commune
  on yama_crm (commune)
  where deleted = false;

-- Recherche texte plein sur les contacts (noms, adresses)
create index if not exists idx_yama_crm_nom_trgm
  on yama_crm using gin (nom gin_trgm_ops)
  where deleted = false;

-- yama_history
create index if not exists idx_yama_history_doc_num
  on yama_history (doc_num);

create index if not exists idx_yama_history_doc_type
  on yama_history (doc_type)
  where deleted = false;

create index if not exists idx_yama_history_client_nom
  on yama_history (client_nom)
  where deleted = false;

create index if not exists idx_yama_history_saved_at
  on yama_history (saved_at desc)
  where deleted = false;

create index if not exists idx_yama_history_total_ttc
  on yama_history (total_ttc)
  where deleted = false and doc_type in ('devis','facture');

-- yama_devis_status
create index if not exists idx_yama_devis_status_status
  on yama_devis_status (status)
  where status is not null;

-- yama_pdf_documents
create index if not exists idx_yama_pdf_documents_doc_num
  on yama_pdf_documents (doc_num);

-- yama_sous_traitants
create index if not exists idx_yama_sous_traitants_nom_trgm
  on yama_sous_traitants using gin (nom gin_trgm_ops);

-- ───────────────────────────────────────────────────────────────────────────
-- 13. TRIGGER : mise à jour automatique de updated_at
-- ───────────────────────────────────────────────────────────────────────────

create or replace function yama_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Applique le trigger sur chaque table
do $$
declare t text;
begin
  foreach t in array array[
    'yama_crm','yama_history','yama_devis_status',
    'yama_pdf_documents','yama_st_paid','yama_client_paid',
    'yama_sous_traitants','yama_settings','yama_counters'
  ] loop
    execute format(
      'create or replace trigger trg_%s_updated_at
         before update on %I
         for each row execute function yama_set_updated_at()',
      t, t
    );
  end loop;
end;
$$;

-- ───────────────────────────────────────────────────────────────────────────
-- 14. FONCTIONS UTILITAIRES
-- ───────────────────────────────────────────────────────────────────────────

-- Calcule le stage pipeline d'un contact à partir de son objet data
create or replace function yama_crm_pipeline_stage(data jsonb)
returns text language sql immutable as $$
  select case
    when coalesce((data->>'deleted')::boolean, false) = true              then 'deleted'
    when coalesce((data->>'devisRefused')::boolean, false) = true
      or data->>'followUpStatus' = 'refused'                              then 'refused'
    when data->>'followUpStatus' = 'chantier'
      or data->>'type' = 'chantier'                                       then 'chantier'
    when coalesce((data->>'finished')::boolean, false) = true
      or data->>'followUpStatus' = 'finished'                             then 'fini'
    when coalesce((data->>'waitingResponse')::boolean, false) = true
      or data->>'followUpStatus' = 'waiting'                              then 'waiting'
    when data->>'followUpStatus' in ('devis_to_make','devis_started')
      or data->>'status' = 'devis_a_preparer'                             then 'devis'
    when (data->>'date') is not null
      and (data->>'date') ~ '^\d{4}-\d{2}-\d{2}$'
      and (data->>'date')::date >= current_date                           then 'rdv'
    when data->>'followUpStatus' = 'recontact'
      or data->>'status' = 'a_recontacter'                                then 'recontact'
    else 'contact'
  end;
$$;

-- Libellé lisible du stage pipeline
create or replace function yama_crm_stage_label(stage text)
returns text language sql immutable as $$
  select case stage
    when 'contact'  then '👥 Contact'
    when 'rdv'      then '📅 RDV planifié'
    when 'recontact' then '📞 À recontacter'
    when 'devis'    then '📋 Devis à faire'
    when 'waiting'  then '⏳ Attente réponse'
    when 'chantier' then '🔨 Chantier'
    when 'fini'     then '✅ Terminé'
    when 'refused'  then '❌ Refusé'
    else '❓ Inconnu'
  end;
$$;

-- Calcule la marge nette recommandée selon les paliers YAMA
create or replace function yama_calc_marge_pct(montant_ht numeric)
returns numeric language sql immutable as $$
  select case
    when montant_ht <     500 then 40
    when montant_ht <    1000 then 38
    when montant_ht <    2000 then 35
    when montant_ht <    5000 then 30
    when montant_ht <   10000 then 25
    else                           20
  end;
$$;

-- Normalise un numéro de téléphone belge (pour déduplication)
create or replace function yama_normalize_tel(tel text)
returns text language sql immutable as $$
  select right(
    regexp_replace(
      regexp_replace(
        regexp_replace(coalesce(tel,''), '[^0-9]', '', 'g'),
        '^0032', '0'
      ),
      '^\+32', '0'
    ),
    9
  );
$$;

-- ───────────────────────────────────────────────────────────────────────────
-- 15. VUE : yama_crm_pipeline_complete
-- Source de vérité unifiée : CRM ↔ Devis ↔ Paiements
-- ───────────────────────────────────────────────────────────────────────────
create or replace view yama_crm_pipeline_complete as
select
  -- ── Identifiants ──
  c.id                                                      as contact_id,
  c.contact_id                                              as contact_uuid,

  -- ── Coordonnées ──
  coalesce(c.data->>'nom', '')                              as nom,
  coalesce(c.data->>'civilite', '')                         as civilite,
  coalesce(c.data->>'tel', '')                              as telephone,
  coalesce(c.data->>'email', '')                            as email,
  coalesce(c.data->>'adresse', '')                          as adresse,
  coalesce(c.data->>'commune', '')                          as commune,
  coalesce(c.data->>'st', '')                               as sous_traitant,
  coalesce(c.data->>'sourceClient', '')                     as source_client,
  coalesce(c.data->>'type', 'devis')                        as type_contact,

  -- ── Pipeline ──
  yama_crm_pipeline_stage(c.data)                           as pipeline_stage,
  yama_crm_stage_label(yama_crm_pipeline_stage(c.data))     as stage_label,

  -- ── RDV ──
  c.data->>'date'                                           as rdv_date,
  c.data->>'heure'                                          as rdv_heure,

  -- ── Notes & suivis ──
  c.data->>'note'                                           as note,
  c.data->>'notesInternes'                                  as notes_internes,
  coalesce((c.data->>'gcal')::boolean, false)               as gcal_added,

  -- ── Timestamps pipeline ──
  c.waiting_response_at,
  c.chantier_confirmed_at,
  c.devis_refused_at,
  c.follow_up_done_at,
  c.saved_at,
  c.updated_at,

  -- ── Devis lié ──
  coalesce(c.data->>'devisDocNum', '')                      as devis_doc_num,
  coalesce(ds.status, 'none')                               as devis_status,
  ds.note                                                   as devis_note,
  h.total_ttc                                               as devis_total_ttc,
  h.total_ht                                                as devis_total_ht,
  h.doc_type                                                as devis_doc_type,
  h.age_batiment                                            as devis_age_batiment,

  -- ── Paiements ──
  coalesce(cp.paid, false)                                  as client_paid,
  cp.paid_at                                                as client_paid_at,
  cp.amount                                                 as client_paid_amount,
  coalesce(sp.paid, false)                                  as st_paid,
  sp.paid_at                                                as st_paid_at,
  sp.amount                                                 as st_paid_amount

from yama_crm c
left join yama_devis_status ds
  on ds.doc_num = c.data->>'devisDocNum'
  and c.data->>'devisDocNum' <> ''
left join yama_history h
  on h.doc_num = c.data->>'devisDocNum'
  and h.deleted = false
left join yama_client_paid cp
  on cp.doc_num = c.data->>'devisDocNum'
left join yama_st_paid sp
  on sp.doc_num = c.data->>'devisDocNum'
where coalesce((c.data->>'deleted')::boolean, false) = false;

-- ───────────────────────────────────────────────────────────────────────────
-- 16. VUE : yama_pipeline_kpi
-- Compteurs par étape pour le tableau de bord
-- ───────────────────────────────────────────────────────────────────────────
create or replace view yama_pipeline_kpi as
select
  count(*) filter (where pipeline_stage = 'contact')        as crm_contacts,
  count(*) filter (where pipeline_stage = 'rdv')            as crm_rdv,
  count(*) filter (where pipeline_stage = 'recontact')      as crm_recontact,
  count(*) filter (where pipeline_stage = 'devis')          as crm_devis,
  count(*) filter (where pipeline_stage = 'waiting')        as crm_attente,
  count(*) filter (where pipeline_stage = 'chantier')       as crm_chantiers,
  count(*) filter (where pipeline_stage = 'fini')           as crm_finis,
  count(*) filter (where pipeline_stage = 'refused')        as crm_refuses,
  count(*)                                                   as crm_total,

  -- Devis liés
  count(*) filter (where devis_status = 'pending')          as devis_en_attente,
  count(*) filter (where devis_status = 'accepted')         as devis_acceptes,
  count(*) filter (where devis_status = 'refused')          as devis_refuses_doc,
  count(*) filter (where devis_status = 'invoiced')         as devis_factures,

  -- Paiements
  count(*) filter (where client_paid = true)                as factures_payees,
  sum(client_paid_amount) filter (where client_paid = true) as ca_encaisse,
  sum(devis_total_ttc) filter (where devis_status = 'accepted') as backlog_ttc

from yama_crm_pipeline_complete;

-- ───────────────────────────────────────────────────────────────────────────
-- 17. VUE : yama_monthly_report
-- Rapport mensuel : volume, conversion, CA
-- ───────────────────────────────────────────────────────────────────────────
create or replace view yama_monthly_report as
select
  date_trunc('month', h.saved_at)::date                     as mois,

  -- Volumes
  count(*)                                                   as nb_documents,
  count(*) filter (where h.doc_type = 'devis'
    and h.deleted = false)                                   as nb_devis,
  count(*) filter (where h.doc_type = 'facture'
    and h.deleted = false)                                   as nb_factures,

  -- Conversion devis
  count(*) filter (
    where h.doc_type = 'devis' and h.deleted = false
    and coalesce(ds.status,'pending') = 'accepted'
  )                                                          as devis_acceptes,
  count(*) filter (
    where h.doc_type = 'devis' and h.deleted = false
    and coalesce(ds.status,'pending') = 'refused'
  )                                                          as devis_refuses,
  round(
    count(*) filter (
      where h.doc_type='devis' and h.deleted=false
        and coalesce(ds.status,'pending')='accepted'
    )::numeric
    / nullif(count(*) filter (
        where h.doc_type='devis' and h.deleted=false), 0) * 100, 1
  )                                                          as taux_conversion_pct,

  -- Financier (factures uniquement)
  sum(h.total_ttc) filter (
    where h.doc_type = 'facture' and h.deleted = false
  )                                                          as ca_facture_ttc,
  sum(h.total_ht) filter (
    where h.doc_type = 'facture' and h.deleted = false
  )                                                          as ca_facture_ht,
  sum(h.total_ttc) filter (
    where h.doc_type = 'facture' and h.deleted = false
    and coalesce(cp.paid, false) = true
  )                                                          as ca_encaisse_ttc,

  -- Panier moyen devis
  round(avg(h.total_ttc) filter (
    where h.doc_type = 'devis' and h.deleted = false
  ), 2)                                                      as panier_moyen_devis,

  -- Marge estimée (total_ht devis - coûts ST)
  sum(
    coalesce(h.total_ht, 0)
    - coalesce(h.cout_materiaux, 0)
    - coalesce(h.autres_couts, 0)
  ) filter (
    where h.doc_type = 'devis' and h.deleted = false
    and coalesce(ds.status,'pending') = 'accepted'
  )                                                          as marge_brute_estimee

from yama_history h
left join yama_devis_status ds on ds.doc_num = h.doc_num
left join yama_client_paid  cp on cp.doc_num = h.doc_num
where h.deleted = false
group by 1
order by 1 desc;

-- ───────────────────────────────────────────────────────────────────────────
-- 18. VUE : yama_sous_traitants_workload
-- Charge de travail par sous-traitant (chantiers actifs + CA en attente)
-- ───────────────────────────────────────────────────────────────────────────
create or replace view yama_sous_traitants_workload as
select
  coalesce(st.nom, h.st_nom, '(sans ST)')                   as st_nom,
  st.tel                                                     as st_tel,
  st.spec                                                    as st_spec,
  st.tarif                                                   as st_tarif_horaire,

  count(h.id) filter (
    where h.doc_type = 'devis' and h.deleted = false
    and coalesce(ds.status,'pending') in ('accepted','done')
  )                                                          as chantiers_actifs,

  sum(h.total_ttc) filter (
    where h.doc_type = 'devis' and h.deleted = false
    and coalesce(ds.status,'pending') in ('accepted','done')
  )                                                          as ca_en_cours_ttc,

  count(h.id) filter (
    where h.doc_type = 'facture' and h.deleted = false
    and coalesce(sp.paid, false) = false
  )                                                          as factures_impayees_count,

  sum(h.total_ttc) filter (
    where h.doc_type = 'facture' and h.deleted = false
    and coalesce(sp.paid, false) = false
  )                                                          as montant_du_au_st

from yama_history h
left join yama_devis_status   ds on ds.doc_num = h.doc_num
left join yama_st_paid        sp on sp.doc_num = h.doc_num
left join yama_sous_traitants st on lower(st.nom) = lower(h.st_nom)
where h.st_nom is not null and h.st_nom <> ''
group by 1, 2, 3, 4
order by chantiers_actifs desc nulls last, ca_en_cours_ttc desc nulls last;

-- ───────────────────────────────────────────────────────────────────────────
-- 19. VUE : yama_rdv_upcoming
-- Prochains RDV (7 jours glissants)
-- ───────────────────────────────────────────────────────────────────────────
create or replace view yama_rdv_upcoming as
select
  c.contact_id                                              as contact_uuid,
  coalesce(c.data->>'nom', '')                              as nom,
  coalesce(c.data->>'tel', '')                              as telephone,
  coalesce(c.data->>'email', '')                            as email,
  coalesce(c.data->>'adresse', '')                          as adresse,
  coalesce(c.data->>'commune', '')                          as commune,
  coalesce(c.data->>'note', '')                             as note,
  c.rdv_date,
  c.data->>'heure'                                          as rdv_heure,
  coalesce(c.data->>'type', 'devis')                        as type_rdv,
  coalesce(c.data->>'st', '')                               as sous_traitant,
  coalesce((c.data->>'gcal')::boolean, false)               as gcal_added,
  c.saved_at

from yama_crm c
where c.rdv_date is not null
  and c.rdv_date >= current_date
  and c.rdv_date <= current_date + interval '7 days'
  and coalesce((c.data->>'deleted')::boolean, false) = false
order by c.rdv_date, c.data->>'heure';

-- ───────────────────────────────────────────────────────────────────────────
-- 20. VUE : yama_factures_impayees
-- Toutes les factures non soldées (relance client)
-- ───────────────────────────────────────────────────────────────────────────
create or replace view yama_factures_impayees as
select
  h.doc_num,
  h.client_nom,
  h.client_tel,
  h.client_email,
  h.client_adresse,
  h.client_ville,
  h.total_ttc,
  h.total_ht,
  h.saved_at                                                as date_facture,
  h.saved_at + interval '30 days'                           as date_echeance,
  now() - (h.saved_at + interval '30 days')                 as depassement,
  coalesce(cp.amount, 0)                                    as montant_paye,
  h.total_ttc - coalesce(cp.amount, 0)                      as reste_a_payer,
  cp.payment_method,
  cp.note                                                   as note_paiement

from yama_history h
left join yama_client_paid cp on cp.doc_num = h.doc_num
where h.doc_type = 'facture'
  and h.deleted = false
  and coalesce(cp.paid, false) = false
order by h.saved_at asc;

-- ───────────────────────────────────────────────────────────────────────────
-- 21. ROW-LEVEL SECURITY (RLS)
-- Mode : accès total via clé anon (app single-user sans auth Supabase)
-- Si auth Supabase est activée plus tard, remplacer ces politiques.
-- ───────────────────────────────────────────────────────────────────────────

alter table yama_crm             enable row level security;
alter table yama_history         enable row level security;
alter table yama_devis_status    enable row level security;
alter table yama_pdf_documents   enable row level security;
alter table yama_st_paid         enable row level security;
alter table yama_client_paid     enable row level security;
alter table yama_sous_traitants  enable row level security;
alter table yama_counters        enable row level security;
alter table yama_settings        enable row level security;

-- Politiques ouvertes (accès anon complet — app sans auth utilisateur)
do $$
declare t text; op text;
begin
  foreach t in array array[
    'yama_crm','yama_history','yama_devis_status','yama_pdf_documents',
    'yama_st_paid','yama_client_paid','yama_sous_traitants',
    'yama_counters','yama_settings'
  ] loop
    foreach op in array array['select','insert','update','delete'] loop
      execute format(
        'create policy %I on %I for %s to anon using (true) with check (true)',
        'anon_' || t || '_' || op, t, op
      );
    end loop;
  end loop;
exception when others then null; -- ignore si politiques déjà créées
end;
$$;

-- ───────────────────────────────────────────────────────────────────────────
-- 22. GRANT PUBLIC (Supabase anon role)
-- ───────────────────────────────────────────────────────────────────────────
grant usage  on schema public to anon;
grant select, insert, update, delete
  on yama_crm, yama_history, yama_devis_status, yama_pdf_documents,
     yama_st_paid, yama_client_paid, yama_sous_traitants,
     yama_counters, yama_settings
  to anon;
grant select
  on yama_crm_pipeline_complete, yama_pipeline_kpi, yama_monthly_report,
     yama_sous_traitants_workload, yama_rdv_upcoming, yama_factures_impayees,
     yama_soustraitants
  to anon;
grant usage, select
  on all sequences in schema public
  to anon;

-- ───────────────────────────────────────────────────────────────────────────
-- 23. TABLE DE RÉFÉRENCE : yama_localstorage_keys
-- Documentation des clés localStorage ↔ tables Supabase
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_localstorage_keys (
  key              text  primary key,
  description      text,
  table_name       text,
  sync_column      text,
  sync_direction   text,
  js_constant      text
);

insert into yama_localstorage_keys
  (key, description, table_name, sync_column, sync_direction, js_constant)
values
  ('yama_crm_v2',           'Contacts CRM complets (array JSON)',
    'yama_crm',          'data',    'push+pull (merge+tombstone)', 'CRM_LS.contacts / LS_CONTACTS'),
  ('yama_history_v3',       'Historique devis & factures (array JSON)',
    'yama_history',       'data',   'push+pull (merge max-ts)',     'LS.history'),
  ('yama_soustraitants_v1', 'Liste sous-traitants (array JSON)',
    'yama_sous_traitants', 'nom',   'push+pull (last-write-wins)',  'LS_ST'),
  ('yama_devis_status_v1',  'Statuts des devis {docNum: {status, note, updatedAt}}',
    'yama_devis_status',  'status', 'push+pull (merge)',            'LS_DEVIS_STATUS'),
  ('yama_st_paid_v1',       'Paiements sous-traitants {docNum: {paid, amount, paid_at}}',
    'yama_st_paid',       'paid',   'push+pull (merge)',            'LS_ST_PAID'),
  ('yama_client_paid_v1',   'Paiements clients {docNum: {paid, amount, paid_at}}',
    'yama_client_paid',   'paid',   'push+pull (merge)',            'LS_CLIENT_PAID'),
  ('yama_current_v3',       'Document en cours de rédaction (objet unique)',
    null,                 null,     'local uniquement',             'LS.current'),
  ('yama_counter_devis',    'Compteur numéro devis (entier)',
    'yama_counters',      'value',  'push (max wins)',              'LS.devisCounter'),
  ('yama_counter_facture',  'Compteur numéro facture (entier)',
    'yama_counters',      'value',  'push (max wins)',              'LS.factureCounter'),
  ('yama_history_deleted_v32','Tombstones historique {docNum: isoDate}',
    null,                 null,     'local uniquement (V32)',       'K.deletedHistory'),
  ('yama_supabase_url',     'URL Supabase plateforme (config)',
    null,                 null,     'config',                       'SUPA_KEYS.url'),
  ('yama_supabase_key',     'Clé anon Supabase plateforme (config)',
    null,                 null,     'config',                       'SUPA_KEYS.key'),
  ('yama_crm_supabase_url', 'URL Supabase CRM (config)',
    null,                 null,     'config',                       'CRM_LS.supaUrl'),
  ('yama_crm_supabase_key', 'Clé anon Supabase CRM (config)',
    null,                 null,     'config',                       'CRM_LS.supaKey'),
  ('yama_gcal_client_id',   'Google Calendar OAuth Client ID',
    null,                 null,     'config',                       'GCAL_LS.clientId'),
  ('yama_gcal_token',       'Google Calendar OAuth Token (Bearer)',
    null,                 null,     'local uniquement',             'GCAL_LS.token')
on conflict (key) do update set
  description    = excluded.description,
  table_name     = excluded.table_name,
  sync_column    = excluded.sync_column,
  sync_direction = excluded.sync_direction,
  js_constant    = excluded.js_constant;

-- ───────────────────────────────────────────────────────────────────────────
-- 24. VÉRIFICATION POST-MIGRATION
-- ───────────────────────────────────────────────────────────────────────────
select
  t.table_name,
  pg_size_pretty(pg_total_relation_size(quote_ident(t.table_name))) as taille,
  (
    select count(*)
    from information_schema.columns c
    where c.table_name = t.table_name and c.table_schema = 'public'
  ) as nb_colonnes
from (
  select table_name
  from information_schema.tables
  where table_schema = 'public'
    and table_name like 'yama_%'
    and table_type = 'BASE TABLE'
) t
order by t.table_name;

-- ═══════════════════════════════════════════════════════════════════════════
-- RÉCAPITULATIF DES TABLES
-- ═══════════════════════════════════════════════════════════════════════════
/*
  TABLE                       CLÉ(S)                   SYNC           USAGE
  ────────────────────────────────────────────────────────────────────────────
  yama_crm                    id / contact_id          push+pull      Contacts CRM + pipeline
  yama_history                id / doc_num             push+pull      Devis & Factures
  yama_devis_status           doc_num                  push+pull      Statut commercial devis
  yama_pdf_documents          id / doc_num             push+pull      Archives PDF base64
  yama_st_paid                doc_num                  push+pull      Paiements sous-traitants
  yama_client_paid            doc_num                  push+pull      Paiements clients
  yama_sous_traitants         id / nom                 push+pull      Carnet sous-traitants
  yama_counters               id ('devis'/'facture')   push (max)     Numérotation
  yama_settings               key                      local          Paramètres app
  yama_localstorage_keys      key                      doc only       Référence LS ↔ SQL

  VUES MÉTIER
  ────────────────────────────────────────────────────────────────────────────
  yama_crm_pipeline_complete  CRM × Devis × Paiements              Tableau de bord principal
  yama_pipeline_kpi           Compteurs par étape                  Widget KPI
  yama_monthly_report         Rapport mensuel CA + conversion      Analyse financière
  yama_sous_traitants_workload Charge ST + impayés                 Gestion sous-traitants
  yama_rdv_upcoming           RDV dans les 7 prochains jours       Agenda
  yama_factures_impayees      Factures non soldées + dépassement   Relance clients
  yama_soustraitants          Alias de yama_sous_traitants         Compat. code compact

  FONCTIONS
  ────────────────────────────────────────────────────────────────────────────
  yama_crm_pipeline_stage(data jsonb) → text            Stage calculé depuis data
  yama_crm_stage_label(stage text) → text               Libellé emoji du stage
  yama_calc_marge_pct(montant_ht numeric) → numeric     Marge recommandée par palier
  yama_normalize_tel(tel text) → text                   Normalisation BE 9 chiffres
  yama_set_updated_at() → trigger                       Auto-updated_at sur toutes tables
*/
