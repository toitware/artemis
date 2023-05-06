-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

CREATE POLICY "Authenticated have full access to pod_descriptions table"
    ON toit_artemis.pod_descriptions
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

CREATE POLICY "Authenticated have full access to pods table"
    ON toit_artemis.pods
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

CREATE POLICY "Authenticated have full access to pod_tags table"
    ON toit_artemis.pod_tags
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);
