-- Copyright (C) 2023 Toitware ApS. All rights reserved.

CREATE OR REPLACE FUNCTION toit_artemis.filter_permitted_device_ids(_device_ids UUID[])
RETURNS UUID[]
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE filtered_device_ids UUID[];
BEGIN
    -- Filter out device-ids the user doesn't have access to
    -- because they aren't in the same org as the device id.
    SELECT array_agg(DISTINCT input.id)
    INTO filtered_device_ids
    FROM unnest(_device_ids) as input(id)
    WHERE is_auth_in_org_of_alias(input.id);

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
SECURITY DEFINER -- For performance reasons.
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
