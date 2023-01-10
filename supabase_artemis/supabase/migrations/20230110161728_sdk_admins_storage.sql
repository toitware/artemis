-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- Artemis administrators.
-- These can upload new service snapshots and generally administrate the system.
CREATE TABLE public.admins (
    "id" "uuid" PRIMARY KEY,

    CONSTRAINT "admins_id_fkey"
      FOREIGN KEY ("id")
      REFERENCES auth.users("id")
      ON UPDATE CASCADE
      ON DELETE CASCADE
);

-- We are going to use the admins table only to check whether
-- an authenticated user is an admin.
-- As such there isn't any policy to access it.
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_artemis_admin()
RETURNS boolean
SECURITY DEFINER
AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM admins WHERE id = auth.uid());
END;
$$ LANGUAGE plpgsql;

-- A view that shows profile information of admins.
-- This table is just to make our lives easier.
CREATE OR REPLACE VIEW admins_profiles
WITH (security_invoker=on)
AS
  SELECT p.*, u.email
  FROM admins a, profiles p, auth.users u
  WHERE a.id = p.id AND a.id = u.id;

-- A table with all supported SDK versions.
CREATE TABLE public.sdks (
    "id" BIGSERIAL PRIMARY KEY,
    "version" "text" NOT NULL UNIQUE,
    -- We will probably add more information about the SDKs in the future.
    "created_at" "timestamptz" NOT NULL DEFAULT now()
);

ALTER TABLE public.sdks ENABLE ROW LEVEL SECURITY;

-- Add a policy that allows admins to modifiy the SDK table.
CREATE POLICY "Admins can modify the SDK table"
    ON public.sdks
    FOR ALL
    TO authenticated
    USING (is_artemis_admin())
    WITH CHECK (is_artemis_admin());

-- Anon and auth users can see the SDK table.
CREATE POLICY "Anon and auth users can see the SDK table"
    ON public.sdks
    FOR SELECT
    TO anon, authenticated
    USING(true);

-- A table with all service snapshots for a given SDK version.
CREATE TABLE public.service_snapshots (
    "id" BIGSERIAL PRIMARY KEY,
    "sdk_id" BIGINT NOT NULL REFERENCES sdks(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    "service_version" "text" NOT NULL,
    "snapshot_name" "text" NOT NULL UNIQUE,
    "created_at" "timestamptz" NOT NULL DEFAULT now(),
    UNIQUE ("sdk_id", "service_version")
);

ALTER TABLE public.service_snapshots ENABLE ROW LEVEL SECURITY;

-- Add a policy that allows admins to modifiy the service builds table.
CREATE POLICY "Admins can modify the service builds table"
    ON public.service_snapshots
    FOR ALL
    TO authenticated
    USING (is_artemis_admin())
    WITH CHECK (is_artemis_admin());

-- Anon and auth users can see the service builds table.
CREATE POLICY "Anon and auth users can see the service builds table"
    ON public.service_snapshots
    FOR SELECT
    TO anon, authenticated
    USING(true);

-- A bucket for storing service snapshots.
INSERT INTO storage.buckets (id, name, public)
    VALUES ('service-snapshots', 'service-snapshots', true);

-- Give admins permissions for service snapshots.
CREATE POLICY "Admins can change service snapshots"
    ON storage.objects
    FOR ALL
    TO authenticated
    USING (bucket_id = 'service-snapshots' AND is_artemis_admin())
    WITH CHECK (bucket_id = 'service-snapshots' AND is_artemis_admin());

-- All users can read service snapshots.
-- The snapshots are public, but then we need to use the public URL.
-- This way, we can also read the file using API calls.
CREATE POLICY "All users can read service snapshots"
    ON storage.objects
    FOR SELECT
    TO anon, authenticated
    USING (bucket_id = 'service-snapshots');
