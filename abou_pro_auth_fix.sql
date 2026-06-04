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
