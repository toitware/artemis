-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- A bucket for storing CLI snapshots.
INSERT INTO storage.buckets (id, name, public)
    VALUES ('cli-snapshots', 'cli-snapshots', false);

-- Give admins permissions for service snapshots.
CREATE POLICY "Admins have access to service snapshots"
    ON storage.objects
    FOR ALL
    TO authenticated
    USING (bucket_id = 'cli-snapshots' AND is_artemis_admin())
    WITH CHECK (bucket_id = 'cli-snapshots' AND is_artemis_admin());
