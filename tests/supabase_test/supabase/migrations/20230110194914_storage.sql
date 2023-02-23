-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- The bucket is non-public.
-- This means that files can't be downloaded using the public URL.
-- Anon users can still access the file if we set the correct policy.
INSERT INTO storage.buckets (id, name, public)
    VALUES ('test-bucket', 'test-bucket', false);

CREATE POLICY "Authenticated can modify"
    ON storage.objects
    FOR ALL
    TO authenticated
    USING (bucket_id = 'test-bucket')
    WITH CHECK (bucket_id = 'test-bucket');

CREATE POLICY "Public can read"
    ON storage.objects
    FOR SELECT
    USING (bucket_id = 'test-bucket');

INSERT INTO storage.buckets (id, name, public)
    VALUES ('test-bucket-public', 'test-bucket-public', true);

CREATE POLICY "Authenticated can modify public bucket"
    ON storage.objects
    FOR ALL
    TO authenticated
    USING (bucket_id = 'test-bucket-public')
    WITH CHECK (bucket_id = 'test-bucket-public');

INSERT INTO storage.buckets (id, name, public)
    VALUES ('test-bucket-private', 'test-bucket-private', false);

CREATE POLICY "Authenticated can write private bucket"
    ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (bucket_id = 'test-bucket-private');

-- This allows to list the available buckets, but not the
-- permissions to work with them.
CREATE POLICY "Authenticated can list all buckets"
    ON storage.buckets
    FOR SELECT
    TO authenticated
    USING (true);
