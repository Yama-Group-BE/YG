-- ============================================================
-- ABOU PRO — Patch sans authentification Supabase
-- Exécutez ce fichier UNE SEULE FOIS dans Supabase SQL Editor
-- ============================================================

-- 1. Supprime la contrainte FK vers auth.users (plus besoin)
ALTER TABLE users_profiles DROP CONSTRAINT IF EXISTS users_profiles_id_fkey;

-- 2. Ajoute un ID par défaut + colonne mot de passe
ALTER TABLE users_profiles ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE users_profiles ADD COLUMN IF NOT EXISTS password text;

-- 3. Désactive RLS sur toutes les tables (accès libre avec la clé anon)
ALTER TABLE users_profiles   DISABLE ROW LEVEL SECURITY;
ALTER TABLE routes           DISABLE ROW LEVEL SECURITY;
ALTER TABLE stops            DISABLE ROW LEVEL SECURITY;
ALTER TABLE assignments      DISABLE ROW LEVEL SECURITY;
ALTER TABLE assignment_stops DISABLE ROW LEVEL SECURITY;
ALTER TABLE tour_logs        DISABLE ROW LEVEL SECURITY;
ALTER TABLE photos           DISABLE ROW LEVEL SECURITY;
ALTER TABLE driver_positions DISABLE ROW LEVEL SECURITY;

-- 4. Crée le compte admin YG-T directement
INSERT INTO users_profiles (identifier, full_name, role, is_active, password)
VALUES ('YG-T', 'Admin', 'admin', true, 'Aboumohandyounesali649005')
ON CONFLICT (identifier) DO UPDATE
  SET password = 'Aboumohandyounesali649005',
      role     = 'admin',
      is_active = true;

SELECT '✓ Patch appliqué. Ouvrez abou_pro.html et connectez-vous.' AS statut;
