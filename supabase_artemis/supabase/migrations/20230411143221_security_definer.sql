-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- For efficiency we need to make the `get_events` function security definer.
-- This means that any function that calls the `get_events` function must
-- ensure that the caller has the correct permissions.
--
-- Note that users can't call the `get_events` function directly, since it
-- isn't in the public schema.
ALTER FUNCTION toit_artemis.get_events SECURITY DEFINER;

CREATE INDEX IF NOT EXISTS events_device_id ON toit_artemis.events (device_id);

-- The public `get_events` function now does a check that the caller can
-- see the device-ids.
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
    -- Filter out device-ids for which the caller doesn't see any events.
    -- The current function is security invoker, so if the caller doesn't have
    -- the rights, they will get an empty list.
    SELECT array_agg(DISTINCT input.id)
    FROM unnest(_device_ids) as input(id)
    WHERE EXISTS
        (SELECT * FROM toit_artemis.events e WHERE input.id = e.device_id)
    INTO filtered_device_ids;

    RETURN QUERY
      SELECT * FROM toit_artemis.get_events(filtered_device_ids, _types, _limit, _since);
END;
$$;
