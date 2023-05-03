-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

-- Use 'toit_artemis' to resolve unqualified variables.
SET search_path TO toit_artemis;

-- The available pods.
CREATE TABLE IF NOT EXISTS toit_artemis.pod_descriptions
(
    id BIGSERIAL NOT NULL PRIMARY KEY,
    fleet_id UUID NOT NULL,
    organization_id UUID NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS pods_fleet_id_name_idx
    ON toit_artemis.pod_descriptions (fleet_id, name);

ALTER TABLE toit_artemis.pod_descriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated have full access to pod_descriptions table"
    ON toit_artemis.pod_descriptions
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

CREATE TABLE IF NOT EXISTS toit_artemis.pods
(
    id UUID NOT NULL PRIMARY KEY,
    pod_description_id BIGINT NOT NULL REFERENCES toit_artemis.pod_descriptions(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pods_pod_description_id_idx
    ON toit_artemis.pods (pod_description_id);

-- Index on insertion date, to make it easier to find the latest
-- pods for a fleet.
CREATE INDEX IF NOT EXISTS pods_created_at_idx
    ON toit_artemis.pods (created_at DESC);

CREATE INDEX IF NOT EXISTS pods_pod_description_id_created_at_idx
    ON toit_artemis.pods (pod_description_id, created_at DESC);

ALTER TABLE toit_artemis.pods ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated have full access to pods table"
    ON toit_artemis.pods
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

CREATE TABLE IF NOT EXISTS toit_artemis.pod_tags
(
    id BIGSERIAL NOT NULL PRIMARY KEY,
    pod_description_id BIGINT NOT NULL REFERENCES toit_artemis.pod_descriptions(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    pod_id UUID NOT NULL REFERENCES toit_artemis.pods(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    tag TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pod_tags_pod_id_idx
    ON toit_artemis.pod_tags (pod_id);

CREATE INDEX IF NOT EXISTS pod_tags_tag_idx
    ON toit_artemis.pod_tags (tag);

CREATE UNIQUE INDEX IF NOT EXISTS pod_tags_pod_description_id_tag_idx
    ON toit_artemis.pod_tags (pod_description_id, tag);

ALTER TABLE toit_artemis.pod_tags ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated have full access to pod_tags table"
    ON toit_artemis.pod_tags
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

CREATE OR REPLACE FUNCTION toit_artemis.upsert_pod_description(
        _fleet_id UUID,
        _organization_id UUID,
        _name TEXT,
        _description TEXT
    )
RETURNS BIGINT
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    pod_description_id BIGINT;
BEGIN
    INSERT INTO toit_artemis.pod_descriptions (fleet_id, organization_id, name, description)
        VALUES (_fleet_id, _organization_id, _name, _description)
        ON CONFLICT (fleet_id, name)
        DO UPDATE SET description = _description
        RETURNING id
        INTO pod_description_id;
    RETURN pod_description_id;
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.upsert_pod(
        _pod_id UUID,
        _pod_description_id BIGINT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO toit_artemis.pods (id, pod_description_id)
        VALUES (_pod_id, _pod_description_id)
        ON CONFLICT (id)
        DO UPDATE SET pod_description_id = _pod_description_id;
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.upsert_pod_tag(
        _pod_description_id BIGINT,
        _pod_id UUID,
        _tag TEXT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO toit_artemis.pod_tags (pod_description_id, pod_id, tag)
        VALUES (_pod_description_id, _pod_id, _tag)
        ON CONFLICT (pod_description_id, tag)
        DO UPDATE SET pod_id = _pod_id;
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.delete_pod_tag(
        _pod_description_id BIGINT,
        _tag TEXT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM toit_artemis.pod_tags
        WHERE pod_description_id = _pod_description_id
        AND tag = _tag;
END;
$$;

CREATE TYPE toit_artemis.Pod AS (
    id UUID,
    pod_description_id BIGINT,
    tags TEXT[]
);

CREATE TYPE toit_artemis.PodDescription AS (
    id BIGINT,
    name TEXT,
    description TEXT,
    tags TEXT[]
);

CREATE OR REPLACE FUNCTION toit_artemis.get_pod_descriptions(
        _fleet_id UUID,
        _tag_since TIMESTAMPTZ
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    description_ids BIGINT[];
BEGIN
    -- Store the relevant ids in a temporary array.
    description_ids := ARRAY(
        SELECT pd.id
        FROM toit_artemis.pod_descriptions pd
        WHERE pd.fleet_id = _fleet_id
    );

    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_ids(description_ids, _tag_since);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_pod_descriptions_by_name(
        _fleet_id UUID,
        _name TEXT[],
        _tag_since TIMESTAMPTZ
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    description_ids BIGINT[];
BEGIN
    -- Store the relevant ids in a temporary array.
    description_ids := ARRAY(
        SELECT pd.id
        FROM toit_artemis.pod_descriptions pd
        WHERE pd.fleet_id = _fleet_id
            AND pd.name = ANY(_name)
    );

    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_ids(description_ids, _tag_since);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_pods(
        _pod_description_id BIGINT,
        _tag_since TIMESTAMPTZ
    )
RETURNS SETOF toit_artemis.Pod
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT p.id, p.pod_description_id,
            CASE
                WHEN pt.pod_id IS NULL
                THEN ARRAY[]::text[]
                ELSE array_agg(pt.tag)
            END
        FROM toit_artemis.pods p
        LEFT JOIN toit_artemis.pod_tags pt ON pt.pod_id = p.id
        WHERE p.pod_description_id = _pod_description_id
            AND pt.created_at >= _tag_since
        GROUP BY p.id, p.pod_description_id;
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_pod_descriptions_by_ids(
        _description_ids BIGINT[],
        _tag_since TIMESTAMPTZ
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT pd.id, pd.name, pd.description,
            CASE
                WHEN pt.pod_description_id IS NULL
                THEN ARRAY[]::text[]
                ELSE ARRAY_AGG(pt.tag)
            END
        FROM toit_artemis.pod_descriptions pd
        LEFT JOIN toit_artemis.pod_tags pt
            ON pt.pod_description_id = pd.id
        WHERE pd.id = ANY(_description_ids)
            AND pt.created_at >= _tag_since
        GROUP BY pd.id, pd.name, pd.description;
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_pods_by_name_and_tag(
        _fleet_id UUID,
        _names_tags JSONB
    )
RETURNS TABLE (pod_id UUID, name TEXT, tag TEXT)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    description_ids BIGINT[];
BEGIN
    RETURN QUERY
        SELECT p.id, pd.name, pt.tag
        FROM toit_artemis.pods p
        JOIN toit_artemis.pod_tags pt ON pt.pod_id = p.id
        JOIN toit_artemis_pod_descriptions pd ON pd.id = p.pod_description_id
        WHERE pd.fleet_id = _fleet_id
            AND pd.name = _names_tags->>'name'
            AND pt.tag = _names_tags->>'label';
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_pod_descriptions_for_pod_ids(
        _fleet_id UUID,
        _pod_ids UUID[]
    )
RETURNS SETOF toit_artemis.Pod
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE release_ids BIGINT[];
BEGIN
    RETURN QUERY
        SELECT _pod_id, p.pod_description_id,
            CASE
                WHEN pt.pod_id IS NULL
                THEN ARRAY[]::text[]
                ELSE ARRAY_AGG(pt.tag)
            END
        FROM unnest(_pod_ids) AS _pod_id
        JOIN toit_artemis.pods p ON p.id = _pod_id
        LEFT JOIN toit_artemis.pod_tags pt
            ON pt.pod_id = _pod_id;
END;
$$;

-- Forwarder functions.
-----------------------

CREATE OR REPLACE FUNCTION public."toit_artemis.upsert_pod_description"(
        _fleet_id UUID,
        _organization_id UUID,
        _name TEXT,
        _description TEXT
    )
RETURNS BIGINT
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN toit_artemis.upsert_pod_description(_fleet_id, _organization_id, _name, _description);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.upsert_pod"(
        _pod_id UUID,
        _pod_description_id BIGINT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM toit_artemis.upsert_pod(_pod_id, _pod_description_id);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.upsert_pod_tag"(
        _pod_description_id BIGINT,
        _pod_id UUID,
        _tag TEXT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM toit_artemis.upsert_pod_tag(_pod_description_id, _pod_id, _tag);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.delete_pod_tag"(
        _pod_description_id BIGINT,
        _tag TEXT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM toit_artemis.delete_pod_tag(_pod_description_id, _tag);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pod_descriptions"(
        _fleet_id UUID,
        _tag_since TIMESTAMPTZ
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions(_fleet_id, _tag_since);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pod_descriptions_by_name"(
        _fleet_id UUID,
        _name TEXT[],
        _tag_since TIMESTAMPTZ
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_name(_fleet_id, _name, _tag_since);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pods"(
        _pod_description_id BIGINT,
        _tag_since TIMESTAMPTZ
    )
RETURNS SETOF toit_artemis.Pod
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods(_pod_description_id, _tag_since);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pod_descriptions_by_ids"(
        _description_ids BIGINT[],
        _tag_since TIMESTAMPTZ
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_ids(_description_ids, _tag_since);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pod_descriptions_for_pod_ids"(
        _fleet_id UUID,
        _pod_ids UUID[]
    )
RETURNS TABLE (id BIGINT, pod_id UUID, tag TEXT[])
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_for_pod_ids(_fleet_id, _pod_ids);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pods_by_name_and_tag"(
        _fleet_id UUID,
        _names_tags JSONB
    )
RETURNS TABLE (pod_id UUID, name TEXT, tag TEXT)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods_by_name_and_tag(_fleet_id, _names_tags);
END;
$$;
