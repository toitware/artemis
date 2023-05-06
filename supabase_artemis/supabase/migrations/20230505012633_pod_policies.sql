-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

CREATE POLICY "Authenticated have full access to pod_descriptions in the org they are member in"
    ON toit_artemis.pod_descriptions
    FOR ALL
    TO authenticated
    USING (public.is_auth_member_of_org(organization_id))
    WITH CHECK (public.is_auth_member_of_org(organization_id));

CREATE POLICY "Authenticated have full access to pods table for descriptions they have access to"
    ON toit_artemis.pods
    FOR ALL
    TO authenticated
    USING (
        EXISTS(
            SELECT 1
            FROM toit_artemis.pod_descriptions pd
            WHERE pd.id = pod_description_id
        )
    )
    WITH CHECK (
        EXISTS(
            SELECT 1
            FROM toit_artemis.pod_descriptions pd
            WHERE pd.id = pod_description_id
        )
    );

CREATE POLICY "Authenticated have full access to pod_tags table for descriptions they have access to"
    ON toit_artemis.pod_tags
    FOR ALL
    TO authenticated
    USING (
        EXISTS(
            SELECT 1
            FROM toit_artemis.pod_descriptions pd
            WHERE pd.id = pod_description_id
        )
    )
    WITH CHECK (
        EXISTS(
            SELECT 1
            FROM toit_artemis.pod_descriptions pd
            WHERE pd.id = pod_description_id
        )
    );
