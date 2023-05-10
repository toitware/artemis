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

CREATE INDEX IF NOT EXISTS pod_descriptions_name_idx
    ON toit_artemis.pod_descriptions (name);

ALTER TABLE toit_artemis.pod_descriptions ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS toit_artemis.pods
(
    id UUID NOT NULL,
    fleet_id UUID NOT NULL,
    pod_description_id BIGINT NOT NULL REFERENCES toit_artemis.pod_descriptions(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    revision int NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, fleet_id)
);

CREATE INDEX IF NOT EXISTS pods_id_idx
    ON toit_artemis.pods (id);

CREATE INDEX IF NOT EXISTS pods_pod_description_id_idx
    ON toit_artemis.pods (pod_description_id);

-- Index on insertion date, to make it easier to find the latest
-- pods for a fleet.
CREATE INDEX IF NOT EXISTS pods_created_at_idx
    ON toit_artemis.pods (created_at DESC);

CREATE INDEX IF NOT EXISTS pods_pod_description_id_created_at_idx
    ON toit_artemis.pods (pod_description_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS pods_pod_description_id_revision_idx
    ON toit_artemis.pods (pod_description_id, revision);

ALTER TABLE toit_artemis.pods ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS toit_artemis.pod_tags
(
    id BIGSERIAL NOT NULL PRIMARY KEY,
    pod_id UUID NOT NULL,
    fleet_id UUID NOT NULL,
    pod_description_id BIGINT NOT NULL REFERENCES toit_artemis.pod_descriptions(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    tag TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (pod_id, fleet_id) REFERENCES toit_artemis.pods(id, fleet_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);

CREATE INDEX IF NOT EXISTS pod_tags_pod_id_idx
    ON toit_artemis.pod_tags (pod_id);

CREATE INDEX IF NOT EXISTS pod_tags_tag_idx
    ON toit_artemis.pod_tags (tag);

CREATE UNIQUE INDEX IF NOT EXISTS pod_tags_pod_description_id_tag_idx
    ON toit_artemis.pod_tags (pod_description_id, tag);

ALTER TABLE toit_artemis.pod_tags ENABLE ROW LEVEL SECURITY;

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

CREATE OR REPLACE FUNCTION toit_artemis.insert_pod(
        _pod_id UUID,
        _pod_description_id BIGINT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    _revision INT;
    _fleet_id UUID;
BEGIN
    -- Lock the pod_description_id row so concurrent updates don't duplicate the revision.
    PERFORM * FROM toit_artemis.pod_descriptions
        WHERE id = _pod_description_id
        FOR UPDATE;

    -- Get a new revision for the pod.
    -- Max + 1 of the existing revisions for this pod_description_id.
    SELECT COALESCE(MAX(revision), 0) + 1
        FROM toit_artemis.pods
        WHERE pod_description_id = _pod_description_id
        INTO _revision;

    SELECT fleet_id
        FROM toit_artemis.pod_descriptions
        WHERE id = _pod_description_id
        INTO _fleet_id;

    INSERT INTO toit_artemis.pods (id, fleet_id, pod_description_id, revision)
        VALUES (_pod_id, _fleet_id, _pod_description_id, _revision);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.insert_pod_tag(
        _pod_id UUID,
        _pod_description_id BIGINT,
        _tag TEXT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO toit_artemis.pod_tags (pod_id, fleet_id, pod_description_id, tag)
        SELECT _pod_id, p.fleet_id, _pod_description_id, _tag
        FROM toit_artemis.pods p
        JOIN toit_artemis.pod_descriptions pd
            ON p.pod_description_id = pd.id
        WHERE p.id = _pod_id;
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
    revision INT,
    tags TEXT[]
);

CREATE TYPE toit_artemis.PodDescription AS (
    id BIGINT,
    name TEXT,
    description TEXT
);

CREATE OR REPLACE FUNCTION toit_artemis.get_pod_descriptions(
        _fleet_id UUID
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
        ORDER BY pd.id DESC
    );

    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_ids(description_ids);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_pod_descriptions_by_names(
        _fleet_id UUID,
        _organization_id UUID,
        _names TEXT[],
        _create_if_missing BOOLEAN
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    i INTEGER := 1;
    name_exists BOOLEAN;
    description_ids BIGINT[];
BEGIN
    IF _create_if_missing THEN
        WHILE i <= array_length(_names, 1) LOOP
            -- Check if the name already exists.
            SELECT EXISTS(
                    SELECT 1
                    FROM toit_artemis.pod_descriptions pd
                    WHERE pd.fleet_id = _fleet_id
                        AND pd.name = _names[i]
                )
                INTO name_exists
                FOR UPDATE;  -- Lock the rows so concurrent updates don't duplicate the name.

            IF NOT name_exists THEN
                -- Create the pod description.
                PERFORM toit_artemis.upsert_pod_description(
                        _fleet_id,
                        _organization_id,
                        _names[i],
                        NULL
                    );
            END IF;

            i := i + 1;
        END LOOP;
    END IF;

    -- Store the relevant ids in a temporary array.
    description_ids := ARRAY(
        SELECT pd.id
        FROM toit_artemis.pod_descriptions pd
        WHERE pd.fleet_id = _fleet_id
            AND pd.name = ANY(_names)
    );

    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_ids(description_ids);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_pod_descriptions_by_ids(
        _description_ids BIGINT[]
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT pd.id, pd.name, pd.description
        FROM toit_artemis.pod_descriptions pd
        WHERE pd.id = ANY(_description_ids);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_pods(
        _pod_description_id BIGINT,
        _limit BIGINT,
        _offset BIGINT
    )
RETURNS SETOF toit_artemis.Pod
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    _pod_ids UUID[];
    _fleet_id UUID;
BEGIN
    SELECT ARRAY(
        SELECT p.id
        FROM toit_artemis.pods p
        WHERE p.pod_description_id = _pod_description_id
        ORDER BY p.created_at DESC
        LIMIT _limit
        OFFSET _offset
    )
    INTO _pod_ids;

    SELECT fleet_id
    FROM toit_artemis.pod_descriptions
    WHERE id = _pod_description_id
    INTO _fleet_id;

    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods_by_ids(_fleet_id, _pod_ids);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_pods_by_ids(
        _fleet_id UUID,
        _pod_ids UUID[]
    )
RETURNS SETOF toit_artemis.Pod
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT p.id, p.pod_description_id, p.revision,
            CASE
                WHEN pt.pod_id IS NULL
                THEN ARRAY[]::text[]
                ELSE array_agg(pt.tag)
            END
        FROM toit_artemis.pods p
        JOIN toit_artemis.pod_descriptions pd
            ON pd.id = p.pod_description_id
            AND pd.fleet_id = _fleet_id
        LEFT JOIN toit_artemis.pod_tags pt
            ON pt.pod_id = p.id
            AND pt.fleet_id = _fleet_id
            AND pt.pod_description_id = p.pod_description_id
        WHERE
            p.id = ANY(_pod_ids)
            AND p.fleet_id = _fleet_id
        GROUP BY p.id, p.created_at, p.revision, p.pod_description_id, pt.pod_id
        ORDER BY p.created_at DESC;
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
BEGIN
    RETURN QUERY
        SELECT pt.pod_id, nt.name, nt.tag
        FROM jsonb_to_recordset(_names_tags) as nt(name TEXT, tag TEXT)
        JOIN toit_artemis.pod_descriptions pd
            ON pd.name = nt.name
            AND pd.fleet_id = _fleet_id
        JOIN toit_artemis.pod_tags pt
            ON pt.pod_description_id = pd.id
            AND pt.fleet_id = _fleet_id
            AND pt.tag = nt.tag;
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

CREATE OR REPLACE FUNCTION public."toit_artemis.insert_pod"(
        _pod_id UUID,
        _pod_description_id BIGINT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM toit_artemis.insert_pod(_pod_id, _pod_description_id);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.insert_pod_tag"(
        _pod_id UUID,
        _pod_description_id BIGINT,
        _tag TEXT
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM toit_artemis.insert_pod_tag(_pod_id, _pod_description_id, _tag);
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
        _fleet_id UUID
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions(_fleet_id);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pod_descriptions_by_names"(
        _fleet_id UUID,
        _organization_id UUID,
        _names TEXT[],
        _create_if_missing BOOLEAN
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_names(_fleet_id, _organization_id, _names, _create_if_missing);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pods"(
        _pod_description_id BIGINT,
        _limit BIGINT,
        _offset BIGINT
    )
RETURNS SETOF toit_artemis.Pod
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods(_pod_description_id, _limit, _offset);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pods_by_ids"(
        _fleet_id UUID,
        _pod_ids UUID[]
    )
RETURNS SETOF toit_artemis.Pod
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods_by_ids(_fleet_id, _pod_ids);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_pod_descriptions_by_ids"(
        _description_ids BIGINT[]
    )
RETURNS SETOF toit_artemis.PodDescription
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_ids(_description_ids);
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
