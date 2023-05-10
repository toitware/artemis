-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

INSERT INTO storage.buckets (id, name, public)
VALUES ('toit-artemis-pods', 'toit-artemis-pods', false);

CREATE POLICY "Authenticated have full access to pod storage in their orgs"
    ON storage.objects
    FOR ALL
    TO authenticated
    USING (
        bucket_id = 'toit-artemis-pods' AND
        public.is_auth_member_of_org((storage.foldername(name))[1]::uuid)
    )
    WITH CHECK (
        bucket_id = 'toit-artemis-pods' AND
        public.is_auth_member_of_org((storage.foldername(name))[1]::uuid)
    );
