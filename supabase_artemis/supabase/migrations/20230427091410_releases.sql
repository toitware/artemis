-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

-- Use 'toit_artemis' to resolve unqualified variables.
SET search_path TO toit_artemis;

-- The available releases.
CREATE TABLE IF NOT EXISTS toit_artemis.releases
(
    id BIGSERIAL NOT NULL PRIMARY KEY,
    organization_id UUID NOT NULL
        REFERENCES public.organizations(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    fleet_id UUID NOT NULL,
    version TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Add uniqueness constraint for fleet_id, version.
CREATE UNIQUE INDEX IF NOT EXISTS releases_fleet_id_version_idx
    ON toit_artemis.releases (fleet_id, version);

CREATE INDEX IF NOT EXISTS releases_organization_id_idx
    ON toit_artemis.releases (organization_id);

ALTER TABLE toit_artemis.releases ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated have full access to releases in the org they are members in"
    ON toit_artemis.releases
    FOR ALL
    TO authenticated
    USING (public.is_auth_member_of_org(organization_id))
    WITH CHECK (public.is_auth_member_of_org(organization_id));

CREATE TABLE IF NOT EXISTS toit_artemis.release_artifacts
(
    id BIGSERIAL NOT NULL PRIMARY KEY,
    release_id BIGINT NOT NULL REFERENCES toit_artemis.releases(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    tag TEXT NOT NULL,
    pod_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS release_artifacts_release_id_idx
    ON toit_artemis.release_artifacts (release_id);

CREATE UNIQUE INDEX IF NOT EXISTS release_artifacts_release_id_tag_idx
    ON toit_artemis.release_artifacts (release_id, tag);

-- Index on release_id and insertion date, to make it easier to find the latest
-- releases for a fleet.
CREATE INDEX IF NOT EXISTS release_artifacts_release_id_created_at_idx
    ON toit_artemis.release_artifacts (release_id, created_at DESC);

CREATE INDEX IF NOT EXISTS release_artifacts_pod_id_idx
    ON toit_artemis.release_artifacts (pod_id);

ALTER TABLE toit_artemis.release_artifacts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated have full access to release_artifacts table for releases they have access to"
    ON toit_artemis.release_artifacts
    FOR ALL
    TO authenticated
    USING (
        EXISTS(
            SELECT 1
            FROM toit_artemis.releases r
            WHERE r.id = release_id
        )
    )
    WITH CHECK (
        EXISTS(
            SELECT 1
            FROM toit_artemis.releases r
            WHERE r.id = release_id
        )
    );

CREATE OR REPLACE FUNCTION toit_artemis.insert_release(
        _fleet_id UUID,
        _organization_id UUID,
        _version TEXT,
        _description TEXT
    )
RETURNS BIGINT
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    release_id BIGINT;
BEGIN
    INSERT INTO toit_artemis.releases (fleet_id, organization_id, version, description)
        VALUES (_fleet_id, _organization_id, _version, _description)
        RETURNING id
        INTO release_id;
    RETURN release_id;
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.add_release_artifacts(
        _release_id BIGINT,
        _artifacts JSONB
)
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    artifact RECORD;
BEGIN
    FOR artifact IN SELECT * FROM jsonb_to_recordset(_artifacts) AS
        (tag TEXT, pod_id UUID)
    LOOP
        INSERT INTO toit_artemis.release_artifacts (release_id, tag, pod_id)
            VALUES (_release_id, artifact.tag, artifact.pod_id);
    END LOOP;
END;
$$;

CREATE TYPE toit_artemis.Release AS (
    id BIGINT,
    fleet_id UUID,
    version TEXT,
    description TEXT,
    created_at TIMESTAMPTZ,
    tags TEXT[]
);

CREATE OR REPLACE FUNCTION toit_artemis.get_releases(
        _fleet_id UUID,
        _limit INTEGER
    )
RETURNS SETOF toit_artemis.Release
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    release_ids BIGINT[];
BEGIN
    -- Store the relevant ids in a temporary array.
    release_ids := ARRAY(
        SELECT r.id
        FROM toit_artemis.releases r
        WHERE r.fleet_id = _fleet_id
        ORDER BY created_at DESC
        LIMIT _limit
    );

    RETURN QUERY
        SELECT * FROM toit_artemis.get_releases_by_ids(release_ids);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_releases_by_ids(
        _release_ids BIGINT[]
    )
RETURNS SETOF toit_artemis.Release
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT r.id, r.fleet_id, r.version, r.description, r.created_at,
            CASE
                WHEN ra.release_id IS NULL
                THEN ARRAY[]::text[]
                ELSE ARRAY_AGG(ra.tag)
            END
        FROM toit_artemis.releases r
        LEFT JOIN toit_artemis.release_artifacts ra
            ON ra.release_id = r.id
        WHERE r.id = ANY(_release_ids)
        GROUP BY r.id, r.fleet_id, r.version, r.description, r.created_at, ra.release_id;
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_release_ids_for_pod_ids(
        _fleet_id UUID,
        _pod_ids UUID[]
    )
RETURNS TABLE (id BIGINT, pod_id UUID, tag TEXT)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE release_ids BIGINT[];
BEGIN
    RETURN QUERY
        SELECT r.id, _pod_id, ra.tag
        FROM unnest(_pod_ids) AS _pod_id
        JOIN toit_artemis.releases r ON fleet_id = _fleet_id
        JOIN toit_artemis.release_artifacts ra
            ON ra.pod_id = _pod_id AND ra.release_id = r.id;
END;
$$;

-- Forwarder functions.
-----------------------

CREATE OR REPLACE FUNCTION public."toit_artemis.insert_release"(
        _fleet_id UUID,
        _organization_id UUID,
        _version TEXT,
        _description TEXT
    )
RETURNS BIGINT
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN toit_artemis.insert_release(_fleet_id, _organization_id, _version, _description);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.add_release_artifacts"(
        _release_id BIGINT,
        _artifacts JSONB
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM toit_artemis.add_release_artifacts(_release_id, _artifacts);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_releases"(
        _fleet_id UUID,
        _limit INTEGER
    )
RETURNS SETOF toit_artemis.Release
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_releases(_fleet_id, _limit);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_release_ids_for_pod_ids"(
        _fleet_id UUID,
        _pod_ids UUID[]
    )
RETURNS TABLE (id BIGINT, pod_id UUID, tag TEXT)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_release_ids_for_pod_ids(_fleet_id, _pod_ids);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_releases_by_ids"(
        _release_ids BIGINT[]
    )
RETURNS SETOF toit_artemis.Release
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_releases_by_ids(_release_ids);
END;
$$;
