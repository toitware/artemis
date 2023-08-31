-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

-- Use 'toit_artemis' to resolve unqualified variables.
SET search_path TO toit_artemis;

DROP FUNCTION toit_artemis.get_pods_by_name_and_tag;
DROP FUNCTION public."toit_artemis.get_pods_by_name_and_tag";

CREATE OR REPLACE FUNCTION toit_artemis.get_pods_by_reference(
        _fleet_id UUID,
        _references JSONB
    )
RETURNS TABLE (pod_id UUID, name TEXT, revision INT, tag TEXT)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT p.id, ref.name, ref.revision, ref.tag
        FROM jsonb_to_recordset(_references) as ref(name TEXT, tag TEXT, revision INT)
        JOIN toit_artemis.pod_descriptions pd
            ON pd.name = ref.name
            AND pd.fleet_id = _fleet_id
        LEFT JOIN toit_artemis.pod_tags pt
            ON pt.pod_description_id = pd.id
            AND pt.fleet_id = _fleet_id
            AND pt.tag = ref.tag
        JOIN toit_artemis.pods p
            ON p.pod_description_id = pd.id
            AND p.fleet_id = _fleet_id
            -- If we found a tag, then we match by id here.
            -- Otherwise we match by revision.
            -- If neither works we don't match and due to the inner join drop the row.
            AND (p.id = pt.pod_id OR p.revision = ref.revision);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pods_by_reference"(
        _fleet_id UUID,
        _references JSONB
    )
RETURNS TABLE (pod_id UUID, name TEXT, revision INT, tag TEXT)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods_by_reference(_fleet_id, _references);
END;
$$;
