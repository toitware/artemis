-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

ALTER TABLE toit_artemis.events
    ALTER COLUMN "timestamp"
    SET DATA TYPE TIMESTAMPTZ;

DROP FUNCTION toit_artemis.get_events;

CREATE OR REPLACE FUNCTION toit_artemis.get_events(
        _device_ids UUID[],
        _types TEXT[],
        _limit INTEGER,
        _since TIMESTAMPTZ)
RETURNS TABLE (device_id UUID, type TEXT, ts TIMESTAMPTZ, data JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    _type TEXT;
BEGIN
    IF ARRAY_LENGTH(_types, 1) = 1 THEN
        _type := _types[1];
        RETURN QUERY
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest(_device_ids) AS p(device_id)
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
            FROM unnest(_device_ids) AS p(device_id)
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
            FROM unnest(_device_ids) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.timestamp >= _since
                ORDER BY e.timestamp DESC
                LIMIT _limit
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC;
    END IF;END;
$$;

DROP FUNCTION public."toit_artemis.get_events";

CREATE OR REPLACE FUNCTION public."toit_artemis.get_events"(
        _device_ids UUID[],
        _types TEXT[],
        _limit INTEGER,
        _since TIMESTAMPTZ DEFAULT '1970-01-01')
RETURNS TABLE (device_id UUID, type TEXT, ts TIMESTAMPTZ, data JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE filtered_device_ids UUID[];
BEGIN
    filtered_device_ids := toit_artemis.filter_permitted_device_ids(_device_ids);

    RETURN QUERY
      SELECT * FROM toit_artemis.get_events(filtered_device_ids, _types, _limit, _since);
END;
$$;
