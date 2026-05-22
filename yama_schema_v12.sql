-- ═══════════════════════════════════════════════════════════════════════
-- YAMA GROUP — Schéma Supabase complet v12
-- Date           : 2026-05-21
-- Compatible avec : yama_platform.html (version courante)
-- ═══════════════════════════════════════════════════════════════════════
-- Instructions :
--   1. Ouvrir Supabase Dashboard > SQL Editor
--   2. Coller ce script et cliquer "Run"
--   3. Script idempotent : peut être relancé sans risque sur une base
--      existante (CREATE IF NOT EXISTS + ADD COLUMN IF NOT EXISTS)
-- ═══════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ───────────────────────────────────────────────────────────────────────
-- UTILITAIRE : met à jour updated_at automatiquement à chaque UPDATE
-- ───────────────────────────────────────────────────────────────────────
create or replace function yama_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 1 : yama_crm
-- Contacts CRM complets, stockés en JSONB (offline-first)
-- ═══════════════════════════════════════════════════════════════════════
--
-- Structure du champ `data` (objet contact complet) :
--   contact_id        text       — identifiant unique (= PK)
--   id                text       — alias legacy de contact_id
--   civilite          text       — 'Monsieur' | 'Madame'
--   nom               text       — nom complet
--   tel               text       — numéro de téléphone
--   adresse           text       — rue + numéro
--   commune           text       — "Ville CP" ex. "Wemmel 1780"
--   note              text       — notes internes CRM
--   date              text       — date RDV (YYYY-MM-DD)
--   heure             text       — heure RDV (HH:MM)
--   type              text       — 'devis' | 'chantier'
--   st                text       — nom du sous-traitant associé
--   sourceClient      text       — origine du lead (Google, Référence…)
--   gcal              boolean    — synchro Google Calendar
--   followUpStatus    text       — '' | 'devis_to_make' | 'devis_started'
--                                   | 'waiting' | 'chantier' | 'finished'
--   waitingResponse   boolean
--   finished          boolean
--   deleted           boolean    — soft delete
--   savedAt           timestamp  — date de création (ne change jamais)
--   updatedAt         timestamp  — dernière modification
--   lastEditedAt      timestamp  — dernière édition manuelle
--   followUpDoneAt    timestamp
--   followUpLastAt    timestamp
--   waitingResponseAt timestamp
--   devisStartedAt    timestamp
--   chantierConfirmedAt timestamp
--   timeline          array      — [{at, label, meta}] max 20 éléments
-- ───────────────────────────────────────────────────────────────────────
create table if not exists yama_crm (
  contact_id  text        primary key,
  data        jsonb       not null default '{}',
  saved_at    timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table yama_crm add column if not exists data       jsonb       not null default '{}';
alter table yama_crm add column if not exists saved_at   timestamptz not null default now();
alter table yama_crm add column if not exists updated_at timestamptz not null default now();

drop trigger if exists yama_crm_set_updated_at on yama_crm;
create trigger yama_crm_set_updated_at
  before update on yama_crm
  for each row execute function yama_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 2 : yama_history
-- Snapshots complets de tous les devis et factures
-- ═══════════════════════════════════════════════════════════════════════
--
-- Structure du champ `data` (snapshot complet au moment de la sauvegarde) :
--   docNum            text       — numéro de document ex. "YG-26-001"
--   docType           text       — 'devis' | 'facture' | 'devis-brouillon'
--   clientNom         text
--   clientTel         text
--   clientEmail       text
--   clientAdresse     text
--   clientCP          text
--   clientVille       text
--   chantierRef       text       — référence chantier
--   chantierAdresse   text
--   chantierCP        text
--   chantierVille     text
--   ageBatiment       text       — 'plus10' (TVA 6%) | 'moins10' (TVA 21%)
--   dateEmission      text       — YYYY-MM-DD
--   dateValidite      text       — YYYY-MM-DD (émission + 30j par défaut)
--   remarques         text
--   notesInternes     text
--   stNom             text       — nom du sous-traitant
--   coutMateriaux     number
--   autresCouts       number
--   lignesClient      array      — [{id, desc, qte, unit, pu, tva}]
--   lignesST          array      — [{id, desc, qte, unit, pu, tva}]
--   totalHTVA         number
--   totalTVA          number
--   totalTTC          number
--   pdfStored         boolean
--   pdfDataUrl        text       — base64 PDF
--   savedAt           timestamp
--   updatedAt         timestamp
-- ───────────────────────────────────────────────────────────────────────
create table if not exists yama_history (
  id          uuid          primary key default gen_random_uuid(),
  doc_num     text          unique not null,
  doc_type    text          not null default '',
  client_name text          not null default '',
  st_nom      text          not null default '',
  total_ttc   numeric(12,2) not null default 0,
  data        jsonb         not null default '{}',
  pdf_stored  boolean       not null default false,
  saved_at    timestamptz   not null default now(),
  updated_at  timestamptz   not null default now(),
  deleted_at  timestamptz
);

alter table yama_history add column if not exists doc_type    text          not null default '';
alter table yama_history add column if not exists client_name text          not null default '';
alter table yama_history add column if not exists st_nom      text          not null default '';
alter table yama_history add column if not exists total_ttc   numeric(12,2) not null default 0;
alter table yama_history add column if not exists data        jsonb         not null default '{}';
alter table yama_history add column if not exists pdf_stored  boolean       not null default false;
alter table yama_history add column if not exists saved_at    timestamptz   not null default now();
alter table yama_history add column if not exists updated_at  timestamptz   not null default now();
alter table yama_history add column if not exists deleted_at  timestamptz;

drop trigger if exists yama_history_set_updated_at on yama_history;
create trigger yama_history_set_updated_at
  before update on yama_history
  for each row execute function yama_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 3 : yama_devis_status
-- Statuts pipeline par numéro de devis
-- ═══════════════════════════════════════════════════════════════════════
--
-- Valeurs possibles pour `status` :
--   'pending'   — en attente de réponse client
--   'accepted'  — devis accepté
--   'refused'   — devis refusé
--   'done'      — travaux terminés
--   'invoiced'  — facturé
--
-- Structure du champ `data` (compatibilité legacy) :
--   { status, note, updatedAt }
-- ───────────────────────────────────────────────────────────────────────
create table if not exists yama_devis_status (
  doc_num    text        primary key,
  status     text        not null default 'pending',
  note       text        not null default '',
  data       jsonb       not null default '{}',
  updated_at timestamptz not null default now()
);

alter table yama_devis_status add column if not exists status     text        not null default 'pending';
alter table yama_devis_status add column if not exists note       text        not null default '';
alter table yama_devis_status add column if not exists data       jsonb       not null default '{}';
alter table yama_devis_status add column if not exists updated_at timestamptz not null default now();

drop trigger if exists yama_devis_status_set_updated_at on yama_devis_status;
create trigger yama_devis_status_set_updated_at
  before update on yama_devis_status
  for each row execute function yama_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 4 : yama_counters
-- Numérotation automatique des devis et factures
-- ═══════════════════════════════════════════════════════════════════════
--
-- Rows attendues :
--   id = 'devis_counter'    — dernier numéro de devis utilisé
--   id = 'facture_counter'  — dernier numéro de facture utilisé
--   id = 'st_updated_at'    — timestamp dernière synchro sous-traitants
-- ───────────────────────────────────────────────────────────────────────
create table if not exists yama_counters (
  id         text        primary key,
  value      integer     not null default 0,
  ts         text        not null default '',
  data       jsonb,
  saved_at   timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table yama_counters add column if not exists value      integer     not null default 0;
alter table yama_counters add column if not exists ts         text        not null default '';
alter table yama_counters add column if not exists data       jsonb;
alter table yama_counters add column if not exists saved_at   timestamptz not null default now();
alter table yama_counters add column if not exists updated_at timestamptz not null default now();

-- Initialiser les compteurs s'ils n'existent pas encore
insert into yama_counters (id, value) values ('devis_counter',   0) on conflict (id) do nothing;
insert into yama_counters (id, value) values ('facture_counter', 0) on conflict (id) do nothing;


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 5 : yama_sous_traitants
-- Carnet d'adresses des sous-traitants (utilisé par le CRM)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists yama_sous_traitants (
  nom        text        primary key,
  source     text        not null default 'crm',
  tel        text        not null default '',
  spec       text        not null default '',
  tarif      text        not null default '',
  updated_at timestamptz not null default now()
);

alter table yama_sous_traitants add column if not exists source     text        not null default 'crm';
alter table yama_sous_traitants add column if not exists tel        text        not null default '';
alter table yama_sous_traitants add column if not exists spec       text        not null default '';
alter table yama_sous_traitants add column if not exists tarif      text        not null default '';
alter table yama_sous_traitants add column if not exists updated_at timestamptz not null default now();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 6 : yama_soustraitants
-- Données JSON complètes des sous-traitants (utilisé par la plateforme)
-- ═══════════════════════════════════════════════════════════════════════
--
-- Structure du champ `data` :
--   { id, nom, tel, spec, tarif, createdAt, source }
-- ───────────────────────────────────────────────────────────────────────
create table if not exists yama_soustraitants (
  id         text        primary key,
  data       jsonb       not null default '{}',
  updated_at timestamptz not null default now()
);

alter table yama_soustraitants add column if not exists data       jsonb       not null default '{}';
alter table yama_soustraitants add column if not exists updated_at timestamptz not null default now();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 7 : yama_st_paid
-- Suivi des paiements vers les sous-traitants (par numéro de devis)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists yama_st_paid (
  doc_num    text        primary key,
  paid       boolean     not null default false,
  paid_at    timestamptz,
  updated_at timestamptz not null default now()
);

alter table yama_st_paid add column if not exists paid       boolean     not null default false;
alter table yama_st_paid add column if not exists paid_at    timestamptz;
alter table yama_st_paid add column if not exists updated_at timestamptz not null default now();

drop trigger if exists yama_st_paid_set_updated_at on yama_st_paid;
create trigger yama_st_paid_set_updated_at
  before update on yama_st_paid
  for each row execute function yama_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 8 : yama_client_paid
-- Suivi des paiements reçus des clients (par numéro de facture)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists yama_client_paid (
  doc_num    text        primary key,
  paid       boolean     not null default false,
  paid_at    timestamptz,
  updated_at timestamptz not null default now()
);

alter table yama_client_paid add column if not exists paid       boolean     not null default false;
alter table yama_client_paid add column if not exists paid_at    timestamptz;
alter table yama_client_paid add column if not exists updated_at timestamptz not null default now();

drop trigger if exists yama_client_paid_set_updated_at on yama_client_paid;
create trigger yama_client_paid_set_updated_at
  before update on yama_client_paid
  for each row execute function yama_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 9 : yama_articles
-- Catalogue des articles / prestations avec prix
-- ═══════════════════════════════════════════════════════════════════════
--
-- Structure du champ `data` :
--   { id, desc, qte, unit, pu, tva, categorie }
-- ───────────────────────────────────────────────────────────────────────
create table if not exists yama_articles (
  article_id text        primary key,
  data       jsonb       not null default '{}',
  saved_at   timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table yama_articles add column if not exists data       jsonb       not null default '{}';
alter table yama_articles add column if not exists saved_at   timestamptz not null default now();
alter table yama_articles add column if not exists updated_at timestamptz not null default now();

drop trigger if exists yama_articles_set_updated_at on yama_articles;
create trigger yama_articles_set_updated_at
  before update on yama_articles
  for each row execute function yama_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 10 : yama_pdf_documents
-- Archives PDF stockées en base64 (cloud backup)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists yama_pdf_documents (
  id         uuid        primary key default gen_random_uuid(),
  doc_num    text        unique not null,
  doc_type   text        not null default '',
  file_name  text        not null default '',
  mime_type  text        not null default 'application/pdf',
  data_url   text,
  size_bytes bigint,
  saved_at   timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table yama_pdf_documents add column if not exists doc_type   text        not null default '';
alter table yama_pdf_documents add column if not exists file_name  text        not null default '';
alter table yama_pdf_documents add column if not exists mime_type  text        not null default 'application/pdf';
alter table yama_pdf_documents add column if not exists data_url   text;
alter table yama_pdf_documents add column if not exists size_bytes bigint;
alter table yama_pdf_documents add column if not exists saved_at   timestamptz not null default now();
alter table yama_pdf_documents add column if not exists updated_at timestamptz not null default now();

drop trigger if exists yama_pdf_documents_set_updated_at on yama_pdf_documents;
create trigger yama_pdf_documents_set_updated_at
  before update on yama_pdf_documents
  for each row execute function yama_set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════
-- INDEX DE PERFORMANCE
-- ═══════════════════════════════════════════════════════════════════════

-- yama_crm : recherches fréquentes par nom, type, statut, date RDV
create index if not exists yama_crm_saved_at_idx      on yama_crm(saved_at desc);
create index if not exists yama_crm_updated_at_idx    on yama_crm(updated_at desc);
create index if not exists yama_crm_data_gin          on yama_crm using gin(data);
create index if not exists yama_crm_nom_idx           on yama_crm((data->>'nom'));
create index if not exists yama_crm_type_idx          on yama_crm((data->>'type'));
create index if not exists yama_crm_status_idx        on yama_crm((data->>'followUpStatus'));
create index if not exists yama_crm_commune_idx       on yama_crm((data->>'commune'));
create index if not exists yama_crm_st_idx            on yama_crm((data->>'st'));
create index if not exists yama_crm_rdv_date_idx      on yama_crm((data->>'date'))
  where (data->>'date') is not null and (data->>'date') <> '';
create index if not exists yama_crm_deleted_idx       on yama_crm((data->>'deleted'))
  where (data->>'deleted') = 'true';

-- yama_history : tri et filtrage par type, client, ST, date
create index if not exists yama_history_saved_at_idx    on yama_history(saved_at desc);
create index if not exists yama_history_updated_at_idx  on yama_history(updated_at desc);
create index if not exists yama_history_doc_type_idx    on yama_history(doc_type);
create index if not exists yama_history_client_name_idx on yama_history(client_name);
create index if not exists yama_history_st_nom_idx      on yama_history(st_nom);
create index if not exists yama_history_total_ttc_idx   on yama_history(total_ttc desc);
create index if not exists yama_history_deleted_idx     on yama_history(deleted_at)
  where deleted_at is not null;
create index if not exists yama_history_data_gin        on yama_history using gin(data);

-- yama_devis_status : filtrage par statut
create index if not exists yama_devis_status_status_idx on yama_devis_status(status);

-- yama_articles : tri par date
create index if not exists yama_articles_saved_at_idx  on yama_articles(saved_at desc);
create index if not exists yama_articles_data_gin      on yama_articles using gin(data);

-- yama_pdf_documents : tri par date
create index if not exists yama_pdf_documents_saved_at_idx on yama_pdf_documents(saved_at desc);

-- yama_sous_traitants : source
create index if not exists yama_sous_traitants_source_idx on yama_sous_traitants(source);


-- ═══════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY (RLS)
-- Usage interne uniquement (anon key), pas d'authentification Supabase
-- ═══════════════════════════════════════════════════════════════════════
alter table yama_crm            enable row level security;
alter table yama_history        enable row level security;
alter table yama_devis_status   enable row level security;
alter table yama_counters       enable row level security;
alter table yama_sous_traitants enable row level security;
alter table yama_soustraitants  enable row level security;
alter table yama_st_paid        enable row level security;
alter table yama_client_paid    enable row level security;
alter table yama_articles       enable row level security;
alter table yama_pdf_documents  enable row level security;

-- Suppression des policies obsolètes (v9 → v11)
drop policy if exists "yg_all_history_v9"          on yama_history;
drop policy if exists "yg_all_counters_v9"         on yama_counters;
drop policy if exists "yg_all_soustraitants_v9"    on yama_soustraitants;
drop policy if exists "yg_all_sous_traitants_v9"   on yama_sous_traitants;
drop policy if exists "yg_all_devis_status_v9"     on yama_devis_status;
drop policy if exists "yg_all_st_paid_v9"          on yama_st_paid;
drop policy if exists "yg_all_client_paid_v9"      on yama_client_paid;
drop policy if exists "yg_all_crm_v9"              on yama_crm;
drop policy if exists "yg_all_articles_v9"         on yama_articles;
drop policy if exists "yg_all_history_v10"         on yama_history;
drop policy if exists "yg_all_counters_v10"        on yama_counters;
drop policy if exists "yg_all_soustraitants_v10"   on yama_soustraitants;
drop policy if exists "yg_all_sous_traitants_v10"  on yama_sous_traitants;
drop policy if exists "yg_all_devis_status_v10"    on yama_devis_status;
drop policy if exists "yg_all_st_paid_v10"         on yama_st_paid;
drop policy if exists "yg_all_client_paid_v10"     on yama_client_paid;
drop policy if exists "yg_all_crm_v10"             on yama_crm;
drop policy if exists "yg_all_articles_v10"        on yama_articles;
drop policy if exists "yg_all_pdf_documents_v10"   on yama_pdf_documents;
drop policy if exists "yg_all_history_v11"         on yama_history;
drop policy if exists "yg_all_counters_v11"        on yama_counters;
drop policy if exists "yg_all_crm_v11"             on yama_crm;
drop policy if exists "yg_all_sous_traitants_v11"  on yama_sous_traitants;
drop policy if exists "yg_all_soustraitants_v11"   on yama_soustraitants;
drop policy if exists "yg_all_devis_status_v11"    on yama_devis_status;
drop policy if exists "yg_all_st_paid_v11"         on yama_st_paid;
drop policy if exists "yg_all_client_paid_v11"     on yama_client_paid;
drop policy if exists "yg_all_articles_v11"        on yama_articles;
drop policy if exists "yg_all_pdf_documents_v11"   on yama_pdf_documents;

-- Suppression des policies v12 (idempotent — pour relance propre)
drop policy if exists "yg_all_crm_v12"             on yama_crm;
drop policy if exists "yg_all_history_v12"         on yama_history;
drop policy if exists "yg_all_devis_status_v12"    on yama_devis_status;
drop policy if exists "yg_all_counters_v12"        on yama_counters;
drop policy if exists "yg_all_sous_traitants_v12"  on yama_sous_traitants;
drop policy if exists "yg_all_soustraitants_v12"   on yama_soustraitants;
drop policy if exists "yg_all_st_paid_v12"         on yama_st_paid;
drop policy if exists "yg_all_client_paid_v12"     on yama_client_paid;
drop policy if exists "yg_all_articles_v12"        on yama_articles;
drop policy if exists "yg_all_pdf_documents_v12"   on yama_pdf_documents;

-- Création des policies v12
create policy "yg_all_crm_v12"            on yama_crm            for all using (true) with check (true);
create policy "yg_all_history_v12"        on yama_history        for all using (true) with check (true);
create policy "yg_all_devis_status_v12"   on yama_devis_status   for all using (true) with check (true);
create policy "yg_all_counters_v12"       on yama_counters       for all using (true) with check (true);
create policy "yg_all_sous_traitants_v12" on yama_sous_traitants for all using (true) with check (true);
create policy "yg_all_soustraitants_v12"  on yama_soustraitants  for all using (true) with check (true);
create policy "yg_all_st_paid_v12"        on yama_st_paid        for all using (true) with check (true);
create policy "yg_all_client_paid_v12"    on yama_client_paid    for all using (true) with check (true);
create policy "yg_all_articles_v12"       on yama_articles       for all using (true) with check (true);
create policy "yg_all_pdf_documents_v12"  on yama_pdf_documents  for all using (true) with check (true);


-- ═══════════════════════════════════════════════════════════════════════
-- REALTIME — activer les publications en temps réel
-- ═══════════════════════════════════════════════════════════════════════
alter publication supabase_realtime add table yama_crm;
alter publication supabase_realtime add table yama_history;
alter publication supabase_realtime add table yama_devis_status;
alter publication supabase_realtime add table yama_counters;
alter publication supabase_realtime add table yama_sous_traitants;
alter publication supabase_realtime add table yama_soustraitants;
alter publication supabase_realtime add table yama_st_paid;
alter publication supabase_realtime add table yama_client_paid;
alter publication supabase_realtime add table yama_articles;
alter publication supabase_realtime add table yama_pdf_documents;


-- ═══════════════════════════════════════════════════════════════════════
-- VUES UTILITAIRES (lecture seule — pour reporting / debug)
-- ═══════════════════════════════════════════════════════════════════════

-- Vue 1 : Tous les contacts actifs avec colonnes extraites
create or replace view yama_crm_active as
select
  contact_id,
  data->>'nom'                              as nom,
  data->>'tel'                              as tel,
  data->>'commune'                          as commune,
  data->>'type'                             as type_contact,
  coalesce(data->>'followUpStatus', '')     as follow_up_status,
  data->>'date'                             as rdv_date,
  data->>'heure'                            as rdv_heure,
  data->>'st'                               as sous_traitant,
  coalesce(
    data->>'sourceClient',
    data->>'clientSource',
    data->>'source_client', ''
  )                                         as source_client,
  (data->>'finished')::boolean              as finished,
  (data->>'waitingResponse')::boolean       as waiting_response,
  saved_at,
  updated_at
from yama_crm
where coalesce(data->>'deleted', 'false') <> 'true';

-- Vue 2 : Tableau de bord pipeline devis + paiements
create or replace view yama_pipeline as
select
  h.doc_num,
  h.doc_type,
  h.client_name,
  h.st_nom,
  h.total_ttc,
  coalesce(ds.status, 'pending')  as devis_status,
  ds.note                         as devis_note,
  coalesce(cp.paid, false)        as client_paid,
  cp.paid_at                      as client_paid_at,
  coalesce(sp.paid, false)        as st_paid,
  sp.paid_at                      as st_paid_at,
  h.saved_at,
  h.updated_at,
  h.deleted_at
from yama_history h
left join yama_devis_status ds on ds.doc_num = h.doc_num
left join yama_client_paid  cp on cp.doc_num = h.doc_num
left join yama_st_paid      sp on sp.doc_num = h.doc_num
where h.deleted_at is null;


-- ═══════════════════════════════════════════════════════════════════════
-- VÉRIFICATION FINALE
-- ═══════════════════════════════════════════════════════════════════════
select
  table_name,
  pg_size_pretty(pg_total_relation_size(quote_ident(table_name))) as taille
from information_schema.tables
where table_schema = 'public'
  and table_name like 'yama_%'
order by table_name;
