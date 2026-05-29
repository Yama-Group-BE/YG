-- ═══════════════════════════════════════════════════════════════════════
-- YAMA GROUP — Schéma Supabase v13 (MIGRATION additive sur v12)
-- Date           : 2026-05-29
-- Compatibilité  : yama_platform.html — toutes versions
-- ═══════════════════════════════════════════════════════════════════════
-- Instructions :
--   1. Supabase Dashboard > SQL Editor
--   2. Coller et "Run" — idempotent, sans risque sur base existante
--   3. Exécuter APRÈS yama_schema_v12.sql (migration additive)
-- ═══════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
-- MIGRATION 1 : Nouvelles colonnes CRM (champs de statut et timestamps)
-- Ajout des champs introduits par les patches V20+ et les fonctions
-- linkDevisRefuseToContactCRM, linkDevisAccepteToContactCRM, etc.
-- ───────────────────────────────────────────────────────────────────────
do $$ begin
  -- Champ : devis_doc_num  (numéro du devis lié au contact)
  if not exists (
    select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='devis_doc_num'
  ) then
    alter table yama_crm add column devis_doc_num text;
  end if;

  -- Champ : devis_refused  (devis refusé par le client)
  if not exists (
    select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='devis_refused'
  ) then
    alter table yama_crm add column devis_refused boolean default false;
  end if;

  -- Champ : devis_refused_at
  if not exists (
    select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='devis_refused_at'
  ) then
    alter table yama_crm add column devis_refused_at timestamptz;
  end if;

  -- Champ : chantier_confirmed_at
  if not exists (
    select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='chantier_confirmed_at'
  ) then
    alter table yama_crm add column chantier_confirmed_at timestamptz;
  end if;

  -- Champ : waiting_response_at
  if not exists (
    select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='waiting_response_at'
  ) then
    alter table yama_crm add column waiting_response_at timestamptz;
  end if;

  -- Champ : follow_up_done_at
  if not exists (
    select 1 from information_schema.columns
    where table_name='yama_crm' and column_name='follow_up_done_at'
  ) then
    alter table yama_crm add column follow_up_done_at timestamptz;
  end if;
end $$;

-- ───────────────────────────────────────────────────────────────────────
-- MIGRATION 2 : Index sur les nouvelles colonnes pour les requêtes rapides
-- ───────────────────────────────────────────────────────────────────────
create index if not exists idx_yama_crm_devis_doc_num
  on yama_crm (devis_doc_num)
  where devis_doc_num is not null;

create index if not exists idx_yama_crm_devis_refused
  on yama_crm (devis_refused)
  where devis_refused = true;

create index if not exists idx_yama_devis_status_status
  on yama_devis_status (status)
  where status is not null;

-- ───────────────────────────────────────────────────────────────────────
-- MIGRATION 3 : Nouvelle vue crm_pipeline_complete
-- Vue unifiée CRM ↔ Devis ↔ Paiements — la "source de vérité" complète
-- ───────────────────────────────────────────────────────────────────────
create or replace view yama_crm_pipeline_complete as
select
  -- ── Contact CRM ──
  c.id                                                    as contact_id,
  c.contact_id                                            as contact_uuid,
  coalesce(c.data->>'nom', '')                            as nom,
  coalesce(c.data->>'civilite', '')                       as civilite,
  coalesce(c.data->>'tel', '')                            as telephone,
  coalesce(c.data->>'email', '')                          as email,
  coalesce(c.data->>'adresse', '') || ', ' ||
    coalesce(c.data->>'commune', '')                      as adresse_complete,
  coalesce(c.data->>'commune', '')                        as commune,
  coalesce(c.data->>'st', '')                             as sous_traitant,
  coalesce(c.data->>'type', 'devis')                      as type_contact,

  -- ── Pipeline stage (calculé) ──
  case
    when coalesce((c.data->>'devisRefused')::boolean, false) = true
      or c.data->>'followUpStatus' = 'refused'            then 'refused'
    when c.data->>'followUpStatus' = 'chantier'
      or c.data->>'type' = 'chantier'                     then 'chantier'
    when coalesce((c.data->>'finished')::boolean, false) = true
      or c.data->>'followUpStatus' = 'finished'           then 'finished'
    when coalesce((c.data->>'waitingResponse')::boolean, false) = true
      or c.data->>'followUpStatus' = 'waiting'            then 'waiting'
    when c.data->>'followUpStatus' in ('devis_to_make','devis_started')
      or c.data->>'status' = 'devis_a_preparer'           then 'devis'
    when c.data->>'date' is not null
      and (c.data->>'date')::date >= current_date         then 'rdv'
    else 'contact'
  end                                                     as pipeline_stage,

  -- ── Statut texte lisible ──
  case
    when coalesce((c.data->>'devisRefused')::boolean, false) = true then '❌ Refusé'
    when c.data->>'followUpStatus' = 'chantier'                     then '🔨 Chantier'
    when coalesce((c.data->>'finished')::boolean, false) = true     then '✅ Fini'
    when coalesce((c.data->>'waitingResponse')::boolean, false)     then '⏳ Attente réponse'
    when c.data->>'followUpStatus' = 'devis_started'                then '📋 Devis en cours'
    else '👥 Contact'
  end                                                     as stage_label,

  -- ── Dates ──
  c.data->>'date'                                         as rdv_date,
  c.data->>'heure'                                        as rdv_heure,
  c.waiting_response_at,
  c.chantier_confirmed_at,
  c.devis_refused_at,
  c.follow_up_done_at,
  c.saved_at,
  c.updated_at,

  -- ── Devis lié ──
  coalesce(c.devis_doc_num, c.data->>'devisDocNum')       as devis_doc_num,
  coalesce(ds.status, 'none')                             as devis_status,
  ds.note                                                 as devis_note,
  h.total_ttc                                             as devis_total_ttc,
  h.doc_type                                              as devis_type,

  -- ── Paiements ──
  coalesce(cp.paid, false)                                as client_paid,
  cp.paid_at                                              as client_paid_at,
  coalesce(sp.paid, false)                                as st_paid,
  sp.paid_at                                              as st_paid_at

from yama_crm c
left join yama_devis_status ds
  on ds.doc_num = coalesce(c.devis_doc_num, c.data->>'devisDocNum')
left join yama_history h
  on h.doc_num = coalesce(c.devis_doc_num, c.data->>'devisDocNum')
  and h.deleted_at is null
left join yama_client_paid cp
  on cp.doc_num = coalesce(c.devis_doc_num, c.data->>'devisDocNum')
left join yama_st_paid sp
  on sp.doc_num = coalesce(c.devis_doc_num, c.data->>'devisDocNum')
where coalesce(c.data->>'deleted', 'false') <> 'true';

-- ───────────────────────────────────────────────────────────────────────
-- MIGRATION 4 : Vue d'analyse mensuelle complète
-- ───────────────────────────────────────────────────────────────────────
create or replace view yama_monthly_report as
select
  date_trunc('month', h.saved_at)::date                  as mois,
  count(*) filter (where h.doc_type = 'devis')            as nb_devis,
  count(*) filter (where h.doc_type = 'facture')          as nb_factures,
  count(*) filter (
    where h.doc_type = 'devis'
    and coalesce(ds.status,'pending') = 'accepted'
  )                                                       as devis_acceptes,
  count(*) filter (
    where h.doc_type = 'devis'
    and coalesce(ds.status,'pending') = 'refused'
  )                                                       as devis_refuses,
  round(
    count(*) filter (
      where h.doc_type='devis' and coalesce(ds.status,'pending')='accepted'
    )::numeric
    / nullif(count(*) filter (where h.doc_type='devis'), 0) * 100, 1
  )                                                       as taux_conversion_pct,
  sum(h.total_ttc) filter (where h.doc_type = 'facture') as ca_facture_ttc,
  sum(h.total_ttc) filter (
    where h.doc_type = 'facture' and coalesce(cp.paid, false) = true
  )                                                       as ca_encaisse_ttc,
  sum(h.total_ht)  filter (where h.doc_type = 'facture') as ca_facture_ht,
  avg(h.total_ttc) filter (where h.doc_type = 'devis')   as panier_moyen_devis
from yama_history h
left join yama_devis_status ds on ds.doc_num = h.doc_num
left join yama_client_paid  cp on cp.doc_num = h.doc_num
where h.deleted_at is null
group by 1
order by 1 desc;

-- ───────────────────────────────────────────────────────────────────────
-- MIGRATION 5 : Vue pipeline KPI (pour le tableau de bord)
-- ───────────────────────────────────────────────────────────────────────
create or replace view yama_pipeline_kpi as
select
  -- CRM
  count(*) filter (where pipeline_stage = 'contact')     as crm_contacts,
  count(*) filter (where pipeline_stage = 'rdv')         as crm_rdv,
  count(*) filter (where pipeline_stage = 'devis')       as crm_devis,
  count(*) filter (where pipeline_stage = 'waiting')     as crm_attente,
  count(*) filter (where pipeline_stage = 'chantier')    as crm_chantiers,
  count(*) filter (where pipeline_stage = 'finished')    as crm_finis,
  count(*) filter (where pipeline_stage = 'refused')     as crm_refuses,
  -- Devis liés
  count(*) filter (where devis_status = 'pending')       as devis_en_attente,
  count(*) filter (where devis_status = 'accepted')      as devis_acceptes,
  count(*) filter (where devis_status = 'refused')       as devis_refuses_doc,
  count(*) filter (where devis_status = 'invoiced')      as devis_factures,
  -- Paiements
  count(*) filter (where client_paid = true)             as factures_payees,
  sum(devis_total_ttc) filter (where client_paid = true) as ca_encaisse
from yama_crm_pipeline_complete;

-- ───────────────────────────────────────────────────────────────────────
-- RÉFÉRENCE : Toutes les clés localStorage utilisées par la plateforme
-- ───────────────────────────────────────────────────────────────────────
-- Table de référence (documentation uniquement — non utilisée par l'app)
create table if not exists yama_localstorage_keys (
  key         text primary key,
  description text,
  table_name  text,
  sync_column text
);

insert into yama_localstorage_keys (key, description, table_name, sync_column) values
  ('yama_crm_v2',           'Contacts CRM complets',              'yama_crm',          'data'),
  ('yama_history_v3',       'Historique devis & factures',        'yama_history',       'data'),
  ('yama_soustraitants_v1', 'Liste sous-traitants',               'yama_sous_traitants','data'),
  ('yama_devis_status_v1',  'Statuts des devis (pending/accepted/refused/invoiced)', 'yama_devis_status', 'status'),
  ('yama_st_paid_v1',       'Paiements sous-traitants par devis', 'yama_st_paid',       'paid'),
  ('yama_client_paid_v1',   'Paiements clients par facture',      'yama_client_paid',   'paid'),
  ('yama_articles_v1',      'Catalogue articles/prestations',     NULL,                 NULL),
  ('yama_num_devis',        'Compteur numéro devis',              'yama_counters',      'val'),
  ('yama_num_facture',      'Compteur numéro facture',            'yama_counters',      'val'),
  ('yama_supabase_url',     'URL Supabase (config)',              NULL,                 NULL),
  ('yama_supabase_key',     'Clé anon Supabase (config)',         NULL,                 NULL)
on conflict (key) do nothing;

-- ───────────────────────────────────────────────────────────────────────
-- SCHÉMA COMPLET — Tableau récapitulatif de toutes les tables
-- ───────────────────────────────────────────────────────────────────────
/*
  TABLE               CLÉS PRIMAIRES       SYNC DIRECTION       USAGE
  ─────────────────────────────────────────────────────────────────────
  yama_crm            id / contact_id      push+pull (merge)    Contacts CRM
  yama_history        id / doc_num         push+pull (merge)    Devis & Factures
  yama_sous_traitants id / nom             push+pull (replace)  Sous-traitants
  yama_devis_status   doc_num              push+pull (upsert)   Statuts devis
  yama_st_paid        doc_num              push+pull (upsert)   Paiement ST
  yama_client_paid    doc_num              push+pull (upsert)   Paiement client
  yama_counters       key                  push (max wins)      Numérotation
  yama_localstorage_keys key               documentation only   Référence
*/

-- ─── Vérification post-migration ────────────────────────────────────
select
  table_name,
  pg_size_pretty(pg_total_relation_size(quote_ident(table_name))) as taille,
  (select count(*) from information_schema.columns
   where table_name = t.table_name and table_schema = 'public')   as nb_colonnes
from (
  select table_name from information_schema.tables
  where table_schema = 'public' and table_name like 'yama_%'
    and table_type = 'BASE TABLE'
) t
order by table_name;
