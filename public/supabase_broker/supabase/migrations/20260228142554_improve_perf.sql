-- Copyright (C) 2026 Toit contributors.

CREATE OR REPLACE FUNCTION toit_artemis.get_devices(_device_ids UUID[])
RETURNS TABLE (device_id UUID, goal JSONB, state JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE filtered_device_ids UUID[];
BEGIN
    -- Using EXECUTE to prevent Postgres from caching a generic query plan.
    -- A generic plan would use Sequential Scans over the RLS policy, timing out.
    EXECUTE '
        SELECT array_agg(DISTINCT d.id)
        FROM unnest($1) as input(id)
        JOIN toit_artemis.devices d ON input.id = d.id
    ' INTO filtered_device_ids USING _device_ids;

    RETURN QUERY EXECUTE '
        SELECT p.device_id, g.goal, d.state
        FROM unnest($1) AS p(device_id)
        LEFT JOIN toit_artemis.goals g USING (device_id)
        LEFT JOIN toit_artemis.devices d ON p.device_id = d.id
    ' USING filtered_device_ids;
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_devices"(_device_ids UUID[])
RETURNS TABLE (device_id UUID, goal JSONB, state JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
      SELECT * FROM toit_artemis.get_devices(_device_ids);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_events(
        _device_ids UUID[],
        _types TEXT[],
        _limit INTEGER,
        _since TIMESTAMPTZ DEFAULT '1970-01-01')
RETURNS TABLE (device_id UUID, type TEXT, ts TIMESTAMPTZ, data JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    _type TEXT;
    filtered_device_ids UUID[];
BEGIN
    -- Using EXECUTE to prevent generic plan caching and forced sequential scans.
    EXECUTE '
        SELECT array_agg(DISTINCT d.id)
        FROM unnest($1) as input(id)
        JOIN toit_artemis.devices d ON input.id = d.id
    ' INTO filtered_device_ids USING _device_ids;

    IF ARRAY_LENGTH(_types, 1) = 1 THEN
        _type := _types[1];
        RETURN QUERY EXECUTE '
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest($1) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.type = $2
                        AND e.timestamp >= $3
                ORDER BY e.timestamp DESC
                LIMIT $4
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC
        ' USING filtered_device_ids, _type, _since, _limit;
    ELSEIF ARRAY_LENGTH(_types, 1) > 1 THEN
        RETURN QUERY EXECUTE '
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest($1) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.type = ANY($2)
                        AND e.timestamp >= $3
                ORDER BY e.timestamp DESC
                LIMIT $4
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC
        ' USING filtered_device_ids, _types, _since, _limit;
    ELSE
        -- Note that 'ARRAY_LENGTH' of an empty array does not return 0 but null.
        RETURN QUERY EXECUTE '
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest($1) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.timestamp >= $2
                ORDER BY e.timestamp DESC
                LIMIT $3
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC
        ' USING filtered_device_ids, _since, _limit;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_events"(
        _device_ids UUID[],
        _types TEXT[],
        _limit INTEGER,
        _since TIMESTAMPTZ DEFAULT '1970-01-01')
RETURNS TABLE (device_id UUID, type TEXT, ts TIMESTAMPTZ, data JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
      SELECT * FROM toit_artemis.get_events(_device_ids, _types, _limit, _since);
END;
$$;
