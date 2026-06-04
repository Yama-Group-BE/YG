-- ═══════════════════════════════════════════════════════════════════════════
-- YAMA GROUP — Schéma Supabase COMPLET v14 (corrigé)
-- Généré le : 2026-06-04
-- Base       : v14 (2026-05-30) avec corrections de compatibilité plateforme
-- Source     : yama_platform.html (toutes les lignes de code analysées)
-- Mode       : Migration ADDITIVE et idempotente — sûr sur base existante
-- ───────────────────────────────────────────────────────────────────────────
-- Corrections appliquées vs v14 original :
--   1. yama_history : doc_type / total_ttc / pdf_stored / deleted_at
--        → colonnes writables (le code les écrit directement via upsert)
--   2. yama_history : deleted  → generated always as (deleted_at is not null)
--        (plus stable que coalesce(data->>'deleted')::boolean)
--   3. yama_history : client_name text ajouté (colonne JS) en plus de
--        client_nom (JSONB généré) — syncPushHistoryV32 écrit client_name
--   4. yama_counters : data jsonb ajouté (photo de profil inter-appareils)
--        + saved_at / updated_at + ts text (code écrit une chaîne ISO)
--   5. yama_soustraitants : TABLE réelle id/data/updated_at
--        (syncSoustraitants insère via .insert() — une VIEW ne suffit pas)
--   6. yama_articles : nouvelle table (catalogue articles/prestations)
--   7. RLS : boucle "for all using(true) with check(true)" — syntaxe valide
--        (la boucle per-opération de v14 faisait échouer SELECT silencieusement)
-- ═══════════════════════════════════════════════════════════════════════════
-- ORDRE D'EXÉCUTION :
--   0. Extensions
--   1. Types ENUM
--   2. Tables (CREATE TABLE IF NOT EXISTS)
--   3. Colonnes additionnelles (ALTER TABLE … IF NOT EXISTS)
--   4. Index
--   5. Triggers (updated_at automatique)
--   6. Fonctions utilitaires
--   7. Vues métier
--   8. Row-Level Security
--   9. GRANT public (anon)
--  10. Realtime
--  11. Table de référence (documentation)
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 0. EXTENSIONS
-- ───────────────────────────────────────────────────────────────────────────
create extension if not exists "uuid-ossp";
create extension if not exists "pg_trgm";
create extension if not exists "pgcrypto";

-- ───────────────────────────────────────────────────────────────────────────
-- NETTOYAGE PRÉALABLE DES VUES
-- Doit être fait AVANT toute modification de colonnes pour éviter
-- "cannot drop columns from view" et pour permettre ALTER/DROP COLUMN.
-- ───────────────────────────────────────────────────────────────────────────
drop view if exists yama_crm_pipeline_complete cascade;
drop view if exists yama_pipeline_kpi cascade;
drop view if exists yama_sous_traitants_workload cascade;
drop view if exists yama_rdv_upcoming cascade;
drop view if exists yama_factures_impayees cascade;
drop view if exists yama_monthly_report cascade;
drop view if exists yama_pipeline cascade;
drop view if exists yama_crm_active cascade;

-- ───────────────────────────────────────────────────────────────────────────
-- 1. TYPES ENUM (immuables côté JS — ne pas modifier sans migration)
-- ───────────────────────────────────────────────────────────────────────────
do $$ begin
  create type yama_devis_status_enum as enum ('pending','accepted','refused','done','invoiced');
  exception when duplicate_object then null;
end $$;

do $$ begin
  create type yama_doc_type_enum as enum ('devis','facture','devis-brouillon');
  exception when duplicate_object then null;
end $$;

do $$ begin
  create type yama_contact_type_enum as enum ('devis','chantier','contact','recontact');
  exception when duplicate_object then null;
end $$;

do $$ begin
  create type yama_pipeline_stage_enum as enum (
    'contact','rdv','recontact','devis','waiting','chantier','fini','refused'
  );
  exception when duplicate_object then null;
end $$;

do $$ begin
  create type yama_age_batiment_enum as enum ('moins10','plus10','inconnu');
  exception when duplicate_object then null;
end $$;

-- ───────────────────────────────────────────────────────────────────────────
-- 2. TABLE : yama_crm
-- Contacts CRM — source : localStorage yama_crm_v2
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_crm (
  id                    bigint      generated always as identity primary key,
  contact_id            text        not null unique,
  data                  jsonb       not null default '{}',

  -- Dénormalisés (lecture seule — calculés depuis data)
  nom                   text        generated always as (data->>'nom') stored,
  civilite              text        generated always as (data->>'civilite') stored,
  tel                   text        generated always as (data->>'tel') stored,
  email                 text        generated always as (data->>'email') stored,
  adresse               text        generated always as (data->>'adresse') stored,
  commune               text        generated always as (data->>'commune') stored,
  type_contact          text        generated always as (coalesce(data->>'type','devis')) stored,
  follow_up_status      text        generated always as (data->>'followUpStatus') stored,
  status                text        generated always as (data->>'status') stored,
  waiting_response      boolean     generated always as (
                                      coalesce((data->>'waitingResponse')::boolean, false)
                                    ) stored,
  devis_refused         boolean     generated always as (
                                      coalesce((data->>'devisRefused')::boolean, false)
                                    ) stored,
  finished              boolean     generated always as (
                                      coalesce((data->>'finished')::boolean, false)
                                    ) stored,
  deleted               boolean     generated always as (
                                      coalesce((data->>'deleted')::boolean, false)
                                    ) stored,
  devis_doc_num         text        generated always as (data->>'devisDocNum') stored,
  source_client         text        generated always as (data->>'sourceClient') stored,
  sous_traitant         text        generated always as (data->>'st') stored,
  rdv_date              text        generated always as (data->>'date') stored,
  rdv_heure             text        generated always as (data->>'heure') stored,

  -- Timestamps pipeline (écrits directement par le code)
  waiting_response_at   timestamptz,
  chantier_confirmed_at timestamptz,
  devis_refused_at      timestamptz,
  follow_up_done_at     timestamptz,
  gcal_added_at         timestamptz,

  saved_at              timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 3. TABLE : yama_history
-- Devis et factures — source : localStorage yama_history / yama_history_v3
-- ⚠ CORRECTION v14 : doc_type / total_ttc / pdf_stored / deleted_at / client_name
--   sont des colonnes WRITABLES (syncPushHistoryV32 les écrit directement).
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_history (
  id              bigint        generated always as identity primary key,
  doc_num         text          not null unique,

  -- Données brutes (source de vérité JS)
  data            jsonb         not null default '{}',

  -- ── Colonnes WRITABLES (écrites par syncPushHistoryV32) ──
  doc_type        text          not null default '',
  client_name     text          not null default '',       -- JS: clientNom → client_name
  total_ttc       numeric(12,2) not null default 0,
  pdf_stored      boolean       not null default false,
  deleted_at      timestamptz,

  -- Tombstone calculé depuis deleted_at (IMMUTABLE — pas de fonction volatile)
  deleted         boolean       generated always as (deleted_at is not null) stored,

  -- ── Colonnes GÉNÉRÉES depuis data (lecture seule) ──
  client_nom      text          generated always as (data->>'clientNom') stored,
  client_tel      text          generated always as (data->>'clientTel') stored,
  client_email    text          generated always as (data->>'clientEmail') stored,
  client_adresse  text          generated always as (data->>'clientAdresse') stored,
  client_cp       text          generated always as (data->>'clientCP') stored,
  client_ville    text          generated always as (data->>'clientVille') stored,
  chantier_ref    text          generated always as (data->>'chantierRef') stored,
  chantier_adresse text         generated always as (data->>'chantierAdresse') stored,
  chantier_cp     text          generated always as (data->>'chantierCP') stored,
  chantier_ville  text          generated always as (data->>'chantierVille') stored,
  age_batiment    text          generated always as (data->>'ageBatiment') stored,
  total_ht        numeric(12,2) generated always as (
                                  case when (data->>'totalHT') ~ '^-?\d+(\.\d+)?$'
                                       then (data->>'totalHT')::numeric else null end
                                ) stored,
  total_tva       numeric(12,2) generated always as (
                                  case when (data->>'totalTVA') ~ '^-?\d+(\.\d+)?$'
                                       then (data->>'totalTVA')::numeric else null end
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
  st_nom          text          generated always as (data->>'stNom') stored,
  pdf_file_name   text          generated always as (data->>'pdfFileName') stored,

  saved_at        timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 4. TABLE : yama_devis_status
-- Statut commercial de chaque devis
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_devis_status (
  doc_num         text          not null primary key,
  status          text          not null default 'pending'
                                check (status in ('pending','accepted','refused','done','invoiced')),
  note            text          not null default '',
  data            jsonb         not null default '{}',
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 5. TABLE : yama_pdf_documents
-- Archivage des PDFs générés (base64)
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_pdf_documents (
  id              bigint        generated always as identity primary key,
  doc_num         text          not null unique,
  doc_type        text          not null default 'devis',
  file_name       text          not null default '',
  mime_type       text          not null default 'application/pdf',
  data_url        text,
  size_bytes      bigint,
  saved_at        timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 6. TABLE : yama_st_paid
-- Suivi paiements sous-traitants par devis/facture
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_st_paid (
  doc_num         text          not null primary key,
  paid            boolean       not null default false,
  amount          numeric(10,2),
  paid_at         timestamptz,
  note            text          not null default '',
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 7. TABLE : yama_client_paid
-- Suivi paiements clients par facture
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_client_paid (
  doc_num         text          not null primary key,
  paid            boolean       not null default false,
  amount          numeric(10,2),
  paid_at         timestamptz,
  payment_method  text,
  note            text          not null default '',
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 8. TABLE : yama_sous_traitants
-- Carnet des sous-traitants (CRM) — clé = nom
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_sous_traitants (
  nom             text          not null primary key,
  tel             text          not null default '',
  spec            text          not null default '',
  tarif           numeric(10,2),
  source          text          not null default 'crm',
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 9. TABLE : yama_soustraitants  (⚠ CORRECTION v14 : TABLE réelle, pas VIEW)
-- Données JSON sous-traitants plateforme — clé = id (UUID JS)
-- Le code fait supaClient.from('yama_soustraitants').insert(rows) — une VIEW
-- ne peut pas recevoir d'INSERT. Table séparée de yama_sous_traitants.
-- ───────────────────────────────────────────────────────────────────────────

-- Si yama_soustraitants existe comme VIEW (v14 original), la convertir en TABLE
do $$
begin
  if exists (
    select 1 from information_schema.views
    where table_schema = 'public' and table_name = 'yama_soustraitants'
  ) then
    drop view yama_soustraitants cascade;
  end if;
end $$;

create table if not exists yama_soustraitants (
  id              text          not null primary key,
  data            jsonb         not null default '{}',
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 10. TABLE : yama_counters  (⚠ CORRECTION v14)
-- Numérotation devis/factures + photo de profil partagée
-- Corrections : data jsonb (photo profil), saved_at/updated_at, ts text
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_counters (
  id              text          not null primary key,
  value           integer       not null default 0,
  ts              text          not null default '',       -- chaîne ISO écrite par JS
  data            jsonb,                                   -- ex: {photo, ts} pour profile_photo
  saved_at        timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);

-- Valeurs initiales (idempotent)
insert into yama_counters (id, value) values
  ('devis',          101),
  ('facture',          1),
  ('st_updated_at',    0)
on conflict (id) do nothing;

-- ───────────────────────────────────────────────────────────────────────────
-- 11. TABLE : yama_settings
-- Paramètres de l'application — getSetting() / setSetting()
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_settings (
  key             text          not null primary key,
  value           jsonb         not null default 'null',
  updated_at      timestamptz   not null default now()
);

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
-- 12. TABLE : yama_articles  (⚠ AJOUT v14 corrigé)
-- Catalogue articles / prestations — clé = article_id (UUID JS)
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists yama_articles (
  article_id      text          not null primary key,
  data            jsonb         not null default '{}',
  saved_at        timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);

-- ───────────────────────────────────────────────────────────────────────────
-- 13. TABLE : yama_localstorage_keys  (documentation)
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
    'yama_crm',           'data',   'push+pull (merge+tombstone)', 'CRM_LS.contacts'),
  ('yama_history_v3',       'Historique devis & factures (array JSON)',
    'yama_history',        'data',   'push+pull (merge max-ts)',    'K.history'),
  ('yama_history',          'Alias historique (clé legacy v31)',
    'yama_history',        'data',   'push+pull (merge max-ts)',    'yama_history'),
  ('yama_soustraitants_v1', 'Liste sous-traitants (array JSON)',
    'yama_soustraitants',  'id',     'push+pull (last-write-wins)', 'LS_ST'),
  ('yama_devis_status_v1',  'Statuts des devis {docNum: {status, note, updatedAt}}',
    'yama_devis_status',   'status', 'push+pull (merge)',           'LS_DEVIS_STATUS'),
  ('yama_st_paid_v1',       'Paiements sous-traitants {docNum: {paid, amount, paid_at}}',
    'yama_st_paid',        'paid',   'push+pull (merge)',           'LS_ST_PAID'),
  ('yama_client_paid_v1',   'Paiements clients {docNum: {paid, amount, paid_at}}',
    'yama_client_paid',    'paid',   'push+pull (merge)',           'LS_CLIENT_PAID'),
  ('yama_counter_devis',    'Compteur numéro devis (entier)',
    'yama_counters',       'value',  'push (max wins)',             'K.devisCounter'),
  ('yama_counter_facture',  'Compteur numéro facture (entier)',
    'yama_counters',       'value',  'push (max wins)',             'K.factureCounter'),
  ('yama_history_deleted_v32','Tombstones historique {docNum: isoDate}',
    null,                  null,     'local uniquement (V32)',      'K.deletedHistory'),
  ('yama_supabase_url',     'URL Supabase plateforme',
    null,                  null,     'config',                      'SUPA_KEYS.url'),
  ('yama_supabase_key',     'Clé anon Supabase plateforme',
    null,                  null,     'config',                      'SUPA_KEYS.key')
on conflict (key) do update set
  description    = excluded.description,
  table_name     = excluded.table_name,
  sync_column    = excluded.sync_column,
  sync_direction = excluded.sync_direction,
  js_constant    = excluded.js_constant;

-- ═══════════════════════════════════════════════════════════════════════════
-- COLONNES ADDITIONNELLES (migration additive — idempotent)
-- Pour bases existantes v12/v13 — les nouvelles tables ignorent ce bloc
-- ═══════════════════════════════════════════════════════════════════════════

-- yama_crm : colonnes pipeline optionnelles
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='waiting_response_at') then
    alter table yama_crm add column waiting_response_at timestamptz; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='chantier_confirmed_at') then
    alter table yama_crm add column chantier_confirmed_at timestamptz; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='devis_refused_at') then
    alter table yama_crm add column devis_refused_at timestamptz; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='follow_up_done_at') then
    alter table yama_crm add column follow_up_done_at timestamptz; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='gcal_added_at') then
    alter table yama_crm add column gcal_added_at timestamptz; end if;
end $$;

-- yama_st_paid : colonnes étendues
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_st_paid' and column_name='amount') then
    alter table yama_st_paid add column amount numeric(10,2); end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_st_paid' and column_name='note') then
    alter table yama_st_paid add column note text not null default ''; end if;
end $$;

-- yama_client_paid : colonnes étendues
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_client_paid' and column_name='amount') then
    alter table yama_client_paid add column amount numeric(10,2); end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_client_paid' and column_name='payment_method') then
    alter table yama_client_paid add column payment_method text; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_client_paid' and column_name='note') then
    alter table yama_client_paid add column note text not null default ''; end if;
end $$;

-- yama_sous_traitants : colonnes étendues
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_sous_traitants' and column_name='spec') then
    alter table yama_sous_traitants add column spec text not null default ''; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_sous_traitants' and column_name='tarif') then
    alter table yama_sous_traitants add column tarif numeric(10,2); end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_sous_traitants' and column_name='source') then
    alter table yama_sous_traitants add column source text not null default 'crm'; end if;
end $$;

-- yama_history : supprime les expressions GENERATED si la table vient du v14 original
-- (ALTER COLUMN ... DROP EXPRESSION disponible depuis PostgreSQL 12)
do $$ begin
  if exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='doc_type'
    and is_generated = 'ALWAYS') then
    alter table yama_history alter column doc_type drop expression;
  end if;
  if exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='total_ttc'
    and is_generated = 'ALWAYS') then
    alter table yama_history alter column total_ttc drop expression;
  end if;
  if exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='pdf_stored'
    and is_generated = 'ALWAYS') then
    alter table yama_history alter column pdf_stored drop expression;
  end if;
  if exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='deleted_at'
    and is_generated = 'ALWAYS') then
    alter table yama_history alter column deleted_at drop expression;
  end if;
  if exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='deleted'
    and is_generated = 'ALWAYS') then
    -- DROP COLUMN pour pouvoir recréer avec la bonne expression (deleted_at is not null)
    -- Les vues ont été droppées au début du script — pas de dépendance
    alter table yama_history drop column deleted;
  end if;
end $$;

-- yama_history : colonnes writables ajoutées (si table pré-v14 sans ces colonnes)
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='doc_type') then
    alter table yama_history add column doc_type text not null default ''; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='client_name') then
    alter table yama_history add column client_name text not null default ''; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='total_ttc') then
    alter table yama_history add column total_ttc numeric(12,2) not null default 0; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='pdf_stored') then
    alter table yama_history add column pdf_stored boolean not null default false; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='deleted_at') then
    alter table yama_history add column deleted_at timestamptz; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='st_nom') then
    alter table yama_history add column st_nom text not null default ''; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='saved_at') then
    alter table yama_history add column saved_at timestamptz not null default now(); end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='updated_at') then
    alter table yama_history add column updated_at timestamptz not null default now(); end if;
end $$;

-- yama_history : colonnes générées (ajoutées si absentes sur tables pré-v14)
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='deleted') then
    alter table yama_history add column deleted boolean
      generated always as (deleted_at is not null) stored;
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='client_nom') then
    alter table yama_history add column client_nom text
      generated always as (coalesce(data->>'clientNom', '')) stored;
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='total_ht') then
    alter table yama_history add column total_ht numeric(12,2)
      generated always as (
        case when (data->>'totalHT') ~ '^-?\d+(\.\d+)?$'
             then (data->>'totalHT')::numeric else null end
      ) stored;
  end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_history' and column_name='age_batiment') then
    alter table yama_history add column age_batiment text
      generated always as (data->>'ageBatiment') stored;
  end if;
end $$;

-- yama_counters : colonnes ajoutées (photo de profil + timestamps)
do $$ begin
  if not exists (select 1 from information_schema.columns
    where table_name='yama_counters' and column_name='data') then
    alter table yama_counters add column data jsonb; end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_counters' and column_name='saved_at') then
    alter table yama_counters add column saved_at timestamptz not null default now(); end if;
  if not exists (select 1 from information_schema.columns
    where table_name='yama_counters' and column_name='updated_at') then
    alter table yama_counters add column updated_at timestamptz not null default now(); end if;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- INDEX DE PERFORMANCE
-- ═══════════════════════════════════════════════════════════════════════════

-- yama_crm
create index if not exists idx_crm_contact_id       on yama_crm (contact_id);
create index if not exists idx_crm_tel              on yama_crm (tel) where tel is not null and deleted = false;
create index if not exists idx_crm_follow_up        on yama_crm (follow_up_status) where deleted = false;
create index if not exists idx_crm_devis_doc_num    on yama_crm (devis_doc_num) where devis_doc_num is not null;
create index if not exists idx_crm_rdv_date         on yama_crm (rdv_date) where rdv_date is not null and deleted = false;
create index if not exists idx_crm_commune          on yama_crm (commune) where deleted = false;
create index if not exists idx_crm_nom_trgm         on yama_crm using gin (nom gin_trgm_ops) where deleted = false;
create index if not exists idx_crm_saved_at         on yama_crm (saved_at desc);
create index if not exists idx_crm_data_gin         on yama_crm using gin (data);

-- yama_history
create index if not exists idx_hist_doc_num         on yama_history (doc_num);
create index if not exists idx_hist_doc_type        on yama_history (doc_type) where deleted = false;
create index if not exists idx_hist_client_name     on yama_history (client_name) where deleted = false;
create index if not exists idx_hist_client_nom      on yama_history (client_nom) where deleted = false;
create index if not exists idx_hist_saved_at        on yama_history (saved_at desc) where deleted = false;
create index if not exists idx_hist_total_ttc       on yama_history (total_ttc) where deleted = false;
create index if not exists idx_hist_deleted_at      on yama_history (deleted_at) where deleted_at is not null;
create index if not exists idx_hist_data_gin        on yama_history using gin (data);

-- yama_devis_status
create index if not exists idx_devis_status_status  on yama_devis_status (status);

-- yama_pdf_documents
create index if not exists idx_pdf_doc_num          on yama_pdf_documents (doc_num);
create index if not exists idx_pdf_saved_at         on yama_pdf_documents (saved_at desc);

-- yama_sous_traitants
create index if not exists idx_sous_tr_nom_trgm     on yama_sous_traitants using gin (nom gin_trgm_ops);

-- yama_articles
create index if not exists idx_articles_saved_at    on yama_articles (saved_at desc);
create index if not exists idx_articles_data_gin    on yama_articles using gin (data);

-- ═══════════════════════════════════════════════════════════════════════════
-- TRIGGER : mise à jour automatique de updated_at
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function yama_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'yama_crm', 'yama_history', 'yama_devis_status', 'yama_pdf_documents',
    'yama_st_paid', 'yama_client_paid', 'yama_sous_traitants', 'yama_soustraitants',
    'yama_counters', 'yama_settings', 'yama_articles'
  ] loop
    execute format(
      'create or replace trigger trg_%s_updated_at
         before update on %I
         for each row execute function yama_set_updated_at()',
      replace(t, 'yama_', ''), t
    );
  end loop;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- FONCTIONS UTILITAIRES
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function yama_crm_pipeline_stage(data jsonb)
returns text language sql immutable as $$
  select case
    when coalesce((data->>'deleted')::boolean, false) = true                       then 'deleted'
    when coalesce((data->>'devisRefused')::boolean, false) = true
      or data->>'followUpStatus' = 'refused'                                       then 'refused'
    when data->>'followUpStatus' = 'chantier' or data->>'type' = 'chantier'        then 'chantier'
    when coalesce((data->>'finished')::boolean, false) = true
      or data->>'followUpStatus' = 'finished'                                      then 'fini'
    when coalesce((data->>'waitingResponse')::boolean, false) = true
      or data->>'followUpStatus' = 'waiting'                                       then 'waiting'
    when data->>'followUpStatus' in ('devis_to_make','devis_started')
      or data->>'status' = 'devis_a_preparer'                                      then 'devis'
    when (data->>'date') is not null
      and (data->>'date') ~ '^\d{4}-\d{2}-\d{2}$'
      and (data->>'date')::date >= current_date                                    then 'rdv'
    when data->>'followUpStatus' = 'recontact'
      or data->>'status' = 'a_recontacter'                                         then 'recontact'
    else 'contact'
  end;
$$;

create or replace function yama_crm_stage_label(stage text)
returns text language sql immutable as $$
  select case stage
    when 'contact'   then 'Contact'
    when 'rdv'       then 'RDV planifie'
    when 'recontact' then 'A recontacter'
    when 'devis'     then 'Devis a faire'
    when 'waiting'   then 'Attente reponse'
    when 'chantier'  then 'Chantier'
    when 'fini'      then 'Termine'
    when 'refused'   then 'Refuse'
    else 'Inconnu'
  end;
$$;

create or replace function yama_calc_marge_pct(montant_ht numeric)
returns numeric language sql immutable as $$
  select case
    when montant_ht <     500 then 40
    when montant_ht <    1000 then 38
    when montant_ht <    2000 then 35
    when montant_ht <    5000 then 30
    when montant_ht <   10000 then 25
    else 20
  end;
$$;

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

-- ═══════════════════════════════════════════════════════════════════════════
-- VUES MÉTIER
-- (les vues existantes ont été droppées en début de script)
-- ═══════════════════════════════════════════════════════════════════════════

create or replace view yama_crm_active as
select
  contact_id,
  data->>'nom'                         as nom,
  data->>'tel'                         as tel,
  data->>'commune'                     as commune,
  data->>'type'                        as type_contact,
  coalesce(data->>'followUpStatus','') as follow_up_status,
  data->>'date'                        as rdv_date,
  data->>'heure'                       as rdv_heure,
  data->>'st'                          as sous_traitant,
  coalesce(data->>'sourceClient','')   as source_client,
  saved_at, updated_at
from yama_crm
where coalesce((data->>'deleted')::boolean, false) = false;

create or replace view yama_pipeline as
select
  h.doc_num, h.doc_type, h.client_name, h.st_nom, h.total_ttc,
  coalesce(ds.status,'pending') as devis_status,
  ds.note                        as devis_note,
  coalesce(cp.paid, false)       as client_paid,
  cp.paid_at                     as client_paid_at,
  coalesce(sp.paid, false)       as st_paid,
  sp.paid_at                     as st_paid_at,
  h.saved_at, h.updated_at, h.deleted_at
from yama_history h
left join yama_devis_status ds on ds.doc_num = h.doc_num
left join yama_client_paid  cp on cp.doc_num = h.doc_num
left join yama_st_paid      sp on sp.doc_num = h.doc_num
where h.deleted_at is null;

create or replace view yama_factures_impayees as
select
  h.doc_num,
  h.client_name,
  h.client_nom,
  h.total_ttc,
  h.total_ht,
  h.saved_at                            as date_facture,
  h.saved_at + interval '30 days'       as date_echeance,
  coalesce(cp.amount, 0)                as montant_paye,
  h.total_ttc - coalesce(cp.amount, 0)  as reste_a_payer,
  cp.payment_method,
  cp.note                               as note_paiement
from yama_history h
left join yama_client_paid cp on cp.doc_num = h.doc_num
where h.doc_type = 'facture'
  and h.deleted = false
  and coalesce(cp.paid, false) = false
order by h.saved_at asc;

create or replace view yama_monthly_report as
select
  date_trunc('month', h.saved_at)::date                 as mois,
  count(*)                                               as nb_documents,
  count(*) filter (where h.doc_type='devis'
    and h.deleted=false)                                 as nb_devis,
  count(*) filter (where h.doc_type='facture'
    and h.deleted=false)                                 as nb_factures,
  count(*) filter (
    where h.doc_type='devis' and h.deleted=false
    and coalesce(ds.status,'pending')='accepted'
  )                                                      as devis_acceptes,
  round(
    count(*) filter (
      where h.doc_type='devis' and h.deleted=false
        and coalesce(ds.status,'pending')='accepted'
    )::numeric
    / nullif(count(*) filter (
        where h.doc_type='devis' and h.deleted=false), 0) * 100, 1
  )                                                      as taux_conversion_pct,
  sum(h.total_ttc) filter (
    where h.doc_type='facture' and h.deleted=false
  )                                                      as ca_facture_ttc,
  sum(h.total_ttc) filter (
    where h.doc_type='facture' and h.deleted=false
    and coalesce(cp.paid, false)=true
  )                                                      as ca_encaisse_ttc
from yama_history h
left join yama_devis_status ds on ds.doc_num = h.doc_num
left join yama_client_paid  cp on cp.doc_num = h.doc_num
where h.deleted = false
group by 1
order by 1 desc;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY  (⚠ CORRECTION v14)
-- Utilisation de "for all" — syntaxe valide pour SELECT + INSERT + UPDATE + DELETE.
-- La boucle per-opération de v14 échouait silencieusement sur SELECT
-- (WITH CHECK invalide pour SELECT) bloquant tout accès anon.
-- ═══════════════════════════════════════════════════════════════════════════
alter table yama_crm             enable row level security;
alter table yama_history         enable row level security;
alter table yama_devis_status    enable row level security;
alter table yama_pdf_documents   enable row level security;
alter table yama_st_paid         enable row level security;
alter table yama_client_paid     enable row level security;
alter table yama_sous_traitants  enable row level security;
alter table yama_soustraitants   enable row level security;
alter table yama_counters        enable row level security;
alter table yama_settings        enable row level security;
alter table yama_articles        enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'yama_crm', 'yama_history', 'yama_devis_status', 'yama_pdf_documents',
    'yama_st_paid', 'yama_client_paid', 'yama_sous_traitants', 'yama_soustraitants',
    'yama_counters', 'yama_settings', 'yama_articles'
  ] loop
    -- Nettoyage des anciennes politiques (v9 → v14)
    execute format('drop policy if exists %I on %I', 'yg_all_'||t||'_v9',  t);
    execute format('drop policy if exists %I on %I', 'yg_all_'||t||'_v10', t);
    execute format('drop policy if exists %I on %I', 'yg_all_'||t||'_v11', t);
    execute format('drop policy if exists %I on %I', 'yg_all_'||t||'_v12', t);
    execute format('drop policy if exists %I on %I', 'yg_all_'||t||'_v13', t);
    execute format('drop policy if exists %I on %I', 'yg_all_'||t||'_v14', t);
    execute format('drop policy if exists %I on %I', 'anon_'||t||'_select', t);
    execute format('drop policy if exists %I on %I', 'anon_'||t||'_insert', t);
    execute format('drop policy if exists %I on %I', 'anon_'||t||'_update', t);
    execute format('drop policy if exists %I on %I', 'anon_'||t||'_delete', t);
    -- Politique universelle ouverte (app mono-utilisateur sans auth)
    execute format(
      'create policy %I on %I for all using (true) with check (true)',
      'yg_all_' || t || '_v14c', t
    );
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- GRANT PUBLIC (rôle anon Supabase)
-- ═══════════════════════════════════════════════════════════════════════════
grant usage on schema public to anon;

grant select, insert, update, delete on
  yama_crm, yama_history, yama_devis_status, yama_pdf_documents,
  yama_st_paid, yama_client_paid, yama_sous_traitants, yama_soustraitants,
  yama_counters, yama_settings, yama_articles
to anon;

grant select on
  yama_crm_active, yama_pipeline,
  yama_factures_impayees, yama_monthly_report
to anon;

grant usage, select on all sequences in schema public to anon;

-- ═══════════════════════════════════════════════════════════════════════════
-- REALTIME (publication idempotente)
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  foreach t in array array[
    'yama_crm', 'yama_history', 'yama_devis_status', 'yama_pdf_documents',
    'yama_st_paid', 'yama_client_paid', 'yama_sous_traitants', 'yama_soustraitants',
    'yama_counters', 'yama_settings', 'yama_articles'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table %I', t);
    end if;
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- VÉRIFICATION POST-MIGRATION
-- ═══════════════════════════════════════════════════════════════════════════
select
  t.table_name,
  pg_size_pretty(pg_total_relation_size(quote_ident(t.table_name))) as taille,
  (select count(*) from information_schema.columns c
   where c.table_name = t.table_name and c.table_schema = 'public') as nb_colonnes
from (
  select table_name from information_schema.tables
  where table_schema = 'public' and table_name like 'yama_%' and table_type = 'BASE TABLE'
) t
order by t.table_name;

-- ═══════════════════════════════════════════════════════════════════════════
-- FIN — Schéma v14 corrigé — cohérent avec yama_platform.html
-- ═══════════════════════════════════════════════════════════════════════════
/*
  TABLE                    CLÉ(S)              SYNC           USAGE
  ─────────────────────────────────────────────────────────────────────────
  yama_crm                 contact_id          push+pull      Contacts CRM
  yama_history             doc_num             push+pull      Devis & Factures
  yama_devis_status        doc_num             push+pull      Statut commercial
  yama_pdf_documents       doc_num             push+pull      Archives PDF
  yama_st_paid             doc_num             push+pull      Paiements ST
  yama_client_paid         doc_num             push+pull      Paiements clients
  yama_sous_traitants      nom                 push+pull      Carnet ST (CRM)
  yama_soustraitants       id (UUID JS)        push+pull      ST plateforme JSON
  yama_counters            id                  push (max)     Numérotation + photo
  yama_settings            key                 local          Paramètres app
  yama_articles            article_id          push+pull      Catalogue articles
  yama_localstorage_keys   key                 doc only       Référence LS ↔ SQL
*/
