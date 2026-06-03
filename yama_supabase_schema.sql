-- ═══════════════════════════════════════════════════════════════════════
-- YAMA GROUP — Schéma Supabase complet v13
-- Date           : 2026-06-03
-- À exécuter dans Supabase > SQL Editor (script unique).
-- Idempotent : peut être relancé sans risque sur une base existante.
--
-- Cohérent avec la plateforme yama_platform.html (sync inter-appareils) :
--   • Historique devis/factures (clé 'yama_history' + 'yama_history_v3')
--   • Compteurs id='devis' / id='facture' (numérotation monotone)
--   • Photo de profil partagée  → yama_counters id='profile_photo'
--   • Statuts devis, paiements client/ST, articles, archives PDF, CRM
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
-- TABLE 1 : yama_crm — Contacts CRM (offline-first JSONB)
-- ═══════════════════════════════════════════════════════════════════════
-- data = { contact_id, civilite, nom, tel, adresse, commune,
--          date, heure, type, st, sourceClient, gcal, note,
--          followUpStatus, waitingResponse, finished, deleted,
--          savedAt, updatedAt, followUpDoneAt, followUpLastAt,
--          waitingResponseAt, devisStartedAt, chantierConfirmedAt,
--          timeline:[{at,label,meta}] }
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
-- TABLE 2 : yama_history — Devis & Factures (snapshots complets)
-- ═══════════════════════════════════════════════════════════════════════
-- data = { docNum, docType, clientNom, clientTel, clientEmail,
--          clientAdresse, clientCP, clientVille, chantierRef,
--          chantierAdresse, chantierCP, chantierVille,
--          ageBatiment ('plus10'|'moins10'), dateEmission, dateValidite,
--          remarques, notesInternes, stNom, coutMateriaux, autresCouts,
--          acompteVerse, parentDevisNum, chantierKey,
--          lignesClient:[{id,desc,qte,unit,pu,tva}],
--          lignesST:[{id,desc,qte,unit,pu,tva}],
--          totalHTVA, totalTVA, totalTTC, pdfStored, pdfDataUrl }
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
-- TABLE 3 : yama_devis_status — Pipeline statut des devis
-- ═══════════════════════════════════════════════════════════════════════
-- status : 'pending' | 'accepted' | 'refused' | 'done' | 'invoiced'
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
-- TABLE 4 : yama_counters — Store clé-valeur (numérotation + réglages)
-- ═══════════════════════════════════════════════════════════════════════
-- Lignes utilisées par la plateforme :
--   id='devis'         → value = dernier numéro de devis   (numérotation)
--   id='facture'       → value = dernier numéro de facture (numérotation)
--   id='st_updated_at' → ts    = horodatage carnet sous-traitants
--   id='profile_photo' → data  = { photo:<dataURL JPEG>, ts:<ISO> }
--                        (photo de profil/logo partagée entre appareils)
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

drop trigger if exists yama_counters_set_updated_at on yama_counters;
create trigger yama_counters_set_updated_at
  before update on yama_counters
  for each row execute function yama_set_updated_at();

-- Graines cohérentes avec le code (id='devis'/'facture', base 101 = aucun doc)
insert into yama_counters (id, value) values ('devis',   101) on conflict (id) do nothing;
insert into yama_counters (id, value) values ('facture', 101) on conflict (id) do nothing;

-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 5 : yama_sous_traitants — Carnet sous-traitants (CRM, clé = nom)
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
-- TABLE 6 : yama_soustraitants — Données JSON sous-traitants (plateforme)
-- ═══════════════════════════════════════════════════════════════════════
-- data = { id, nom, tel, spec, tarif, createdAt, source }
create table if not exists yama_soustraitants (
  id         text        primary key,
  data       jsonb       not null default '{}',
  updated_at timestamptz not null default now()
);
alter table yama_soustraitants add column if not exists data       jsonb       not null default '{}';
alter table yama_soustraitants add column if not exists updated_at timestamptz not null default now();

-- ═══════════════════════════════════════════════════════════════════════
-- TABLE 7 : yama_st_paid — Paiements sous-traitants par document
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
-- TABLE 8 : yama_client_paid — Paiements clients par facture
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
-- TABLE 9 : yama_articles — Catalogue articles / prestations
-- ═══════════════════════════════════════════════════════════════════════
-- data = { id, desc, qte, unit, pu, tva, categorie }
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
-- TABLE 10 : yama_pdf_documents — Archives PDF (base64 cloud)
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
create index if not exists yama_history_saved_at_idx    on yama_history(saved_at desc);
create index if not exists yama_history_updated_at_idx  on yama_history(updated_at desc);
create index if not exists yama_history_doc_type_idx    on yama_history(doc_type);
create index if not exists yama_history_client_name_idx on yama_history(client_name);
create index if not exists yama_history_st_nom_idx      on yama_history(st_nom);
create index if not exists yama_history_total_ttc_idx   on yama_history(total_ttc desc);
create index if not exists yama_history_deleted_idx     on yama_history(deleted_at) where deleted_at is not null;
create index if not exists yama_history_data_gin        on yama_history using gin(data);
create index if not exists yama_devis_status_status_idx on yama_devis_status(status);
create index if not exists yama_articles_saved_at_idx   on yama_articles(saved_at desc);
create index if not exists yama_articles_data_gin       on yama_articles using gin(data);
create index if not exists yama_pdf_saved_at_idx        on yama_pdf_documents(saved_at desc);
create index if not exists yama_sous_traitants_src_idx  on yama_sous_traitants(source);

-- ═══════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY (accès complet — clé anon partagée mono-utilisateur)
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

-- Nettoyage des anciennes policies (v9 → v13) puis recréation propre v13
do $$
declare
  t  text;
  v  text;
  pol text;
begin
  foreach t in array array[
    'yama_crm','yama_history','yama_devis_status','yama_counters',
    'yama_sous_traitants','yama_soustraitants','yama_st_paid',
    'yama_client_paid','yama_articles','yama_pdf_documents'
  ] loop
    foreach v in array array['v9','v10','v11','v12','v13'] loop
      pol := 'yg_all_' || t || '_' || v;
      execute format('drop policy if exists %I on %I', pol, t);
    end loop;
    execute format(
      'create policy %I on %I for all using (true) with check (true)',
      'yg_all_' || t || '_v13', t
    );
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════
-- REALTIME (idempotent — n'ajoute que si pas encore publié)
-- ═══════════════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  foreach t in array array[
    'yama_crm','yama_history','yama_devis_status','yama_counters',
    'yama_sous_traitants','yama_soustraitants','yama_st_paid',
    'yama_client_paid','yama_articles','yama_pdf_documents'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table %I', t);
    end if;
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════
-- VUES UTILITAIRES
-- ═══════════════════════════════════════════════════════════════════════
create or replace view yama_crm_active as
select
  contact_id,
  data->>'nom'                          as nom,
  data->>'tel'                          as tel,
  data->>'commune'                      as commune,
  data->>'type'                         as type_contact,
  coalesce(data->>'followUpStatus','')  as follow_up_status,
  data->>'date'                         as rdv_date,
  data->>'heure'                        as rdv_heure,
  data->>'st'                           as sous_traitant,
  coalesce(data->>'sourceClient',
           data->>'clientSource','')    as source_client,
  saved_at, updated_at
from yama_crm
where coalesce(data->>'deleted','false') <> 'true';

create or replace view yama_pipeline as
select
  h.doc_num, h.doc_type, h.client_name, h.st_nom, h.total_ttc,
  coalesce(ds.status,'pending') as devis_status,
  ds.note                       as devis_note,
  coalesce(cp.paid, false)      as client_paid,
  cp.paid_at                    as client_paid_at,
  coalesce(sp.paid, false)      as st_paid,
  sp.paid_at                    as st_paid_at,
  h.saved_at, h.updated_at, h.deleted_at
from yama_history h
left join yama_devis_status ds on ds.doc_num = h.doc_num
left join yama_client_paid  cp on cp.doc_num = h.doc_num
left join yama_st_paid      sp on sp.doc_num = h.doc_num
where h.deleted_at is null;

-- ═══════════════════════════════════════════════════════════════════════
-- FIN — Schéma v13 cohérent avec yama_platform.html
-- ═══════════════════════════════════════════════════════════════════════
