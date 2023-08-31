-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

CREATE OR REPLACE FUNCTION toit_artemis.filter_permitted_device_ids(_device_ids UUID[])
RETURNS UUID[]
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE filtered_device_ids UUID[];
BEGIN
    -- Filter out device-ids the user doesn't have access to.
    -- The current function is security invoker, so if the caller doesn't have
    -- the rights, they will get an empty list.
    SELECT array_agg(DISTINCT input.id)
    FROM unnest(_device_ids) as input(id)
    JOIN toit_artemis.devices USING(id)
    INTO filtered_device_ids;

    RETURN filtered_device_ids;
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
DECLARE filtered_device_ids UUID[];
BEGIN
    filtered_device_ids := toit_artemis.filter_permitted_device_ids(_device_ids);

    RETURN QUERY
      SELECT * FROM toit_artemis.get_events(filtered_device_ids, _types, _limit, _since);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.get_devices"(_device_ids UUID[])
RETURNS TABLE (device_id UUID, goal JSONB, state JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE filtered_device_ids UUID[];
BEGIN
    filtered_device_ids := toit_artemis.filter_permitted_device_ids(_device_ids);

    RETURN QUERY
        SELECT * FROM toit_artemis.get_devices(filtered_device_ids);
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.get_devices(_device_ids UUID[])
RETURNS TABLE (device_id UUID, goal JSONB, state JSONB)
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT p.device_id, g.goal, d.state
        FROM unnest(_device_ids) AS p(device_id)
        LEFT JOIN toit_artemis.goals g USING (device_id)
        LEFT JOIN toit_artemis.devices d ON p.device_id = d.id;
END;
$$;
