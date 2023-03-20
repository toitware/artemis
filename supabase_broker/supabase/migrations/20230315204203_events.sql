-- Copyright (C) 2023 Toitware ApS. All rights reserved.

SET search_path TO toit_artemis;

CREATE TABLE IF NOT EXISTS toit_artemis.events
(
    id SERIAL PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES toit_artemis.devices (id) ON DELETE CASCADE,
    timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
    type TEXT NOT NULL,
    data JSONB NOT NULL
);

-- Enable RLS.
ALTER TABLE toit_artemis.events ENABLE ROW LEVEL SECURITY;

-- Give authenticated users access to the functions and to the storage.
CREATE POLICY "Authenticated have full access to events table"
  ON toit_artemis.events
  FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE OR REPLACE FUNCTION toit_artemis.report_event(_device_id UUID, _type TEXT, _data JSONB)
RETURNS VOID
SECURITY DEFINER -- Security definer so that the device can call this function.
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO toit_artemis.events (device_id, type, data)
      VALUES (_device_id, _type, _data);
END;
$$;

CREATE INDEX IF NOT EXISTS events_device_id_type_timestamp_idx
    ON toit_artemis.events (device_id, type, timestamp DESC);

CREATE OR REPLACE FUNCTION toit_artemis.get_events(
        _device_ids UUID[],
        _types TEXT[],
        _limit INTEGER,
        _since TIMESTAMP)
RETURNS TABLE (device_id UUID, type TEXT, ts TIMESTAMP, data JSONB)
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

-- Create the forwarder functions.

SET search_path TO public;

CREATE OR REPLACE FUNCTION public."toit_artemis.report_event"(_device_id UUID, _type TEXT, _data JSONB)
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM toit_artemis.report_event(_device_id, _type, _data);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_events"(
        _device_ids UUID[],
        _types TEXT[],
        _limit INTEGER,
        _since TIMESTAMP DEFAULT '1970-01-01')
RETURNS TABLE (device_id UUID, type TEXT, ts TIMESTAMP, data JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
   RETURN QUERY
     SELECT * FROM toit_artemis.get_events(_device_ids, _types, _limit, _since);
END;
$$;
