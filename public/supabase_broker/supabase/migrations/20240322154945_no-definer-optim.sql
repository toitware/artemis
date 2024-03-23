-- Copyright (C) 2024 Toitware ApS. All rights reserved.

CREATE OR REPLACE FUNCTION toit_artemis.get_devices(_device_ids UUID[])
RETURNS TABLE (device_id UUID, goal JSONB, state JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE filtered_device_ids UUID[];
BEGIN
    -- We are using the RLS to filter out device ids the invoker doesn't have
    -- access to. This is a performance optimization.
    SELECT array_agg(DISTINCT d.id)
    INTO filtered_device_ids
    FROM unnest(_device_ids) as input(id)
    JOIN toit_artemis.devices d ON input.id = d.id;

    RETURN QUERY
        SELECT p.device_id, g.goal, d.state
        FROM unnest(filtered_device_ids) AS p(device_id)
        LEFT JOIN toit_artemis.goals g USING (device_id)
        LEFT JOIN toit_artemis.devices d ON p.device_id = d.id;
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
    -- We are using the RLS to filter out device ids the invoker doesn't have
    -- access to. This is a performance optimization.
    SELECT array_agg(DISTINCT d.id)
    INTO filtered_device_ids
    FROM unnest(_device_ids) as input(id)
    JOIN toit_artemis.devices d ON input.id = d.id;

    IF ARRAY_LENGTH(_types, 1) = 1 THEN
        _type := _types[1];
        RETURN QUERY
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest(filtered_device_ids) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.type = _type
                        AND e.timestamp >= _since
                ORDER BY e.timestamp DESC
                LIMIT _limit
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC;
    ELSEIF ARRAY_LENGTH(_types, 1) > 1 THEN
        RETURN QUERY
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest(filtered_device_ids) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.type = ANY(_types)
                        AND e.timestamp >= _since
                ORDER BY e.timestamp DESC
                LIMIT _limit
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC;
    ELSE
        -- Note that 'ARRAY_LENGTH' of an empty array does not return 0 but null.
        RETURN QUERY
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest(filtered_device_ids) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.timestamp >= _since
                ORDER BY e.timestamp DESC
                LIMIT _limit
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC;
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

DROP FUNCTION toit_artemis.filter_permitted_device_ids(_device_ids UUID[]);
