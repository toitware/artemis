-- Copyright (C) 2023 Toitware ApS. All rights reserved.

CREATE INDEX IF NOT EXISTS events_device_id_timestamp_idx
    ON toit_artemis.events (device_id, timestamp DESC);

-- The public `get_events` function does a check that the caller can
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
DECLARE filtered_device_ids_org UUID[];
DECLARE filtered_device_ids UUID[];
BEGIN
    -- Start by filtering out device-ids that the caller shouldn't have access to
    -- because they aren't in the same org as the device id.
    SELECT array_agg(DISTINCT input.id)
    INTO filtered_device_ids_org
    FROM unnest(_device_ids) as input(id)
    WHERE is_auth_in_org_of_alias(input.id);

    -- Filter out device-ids for which the caller doesn't see any events.
    -- In theory this shouldn't be necessary, but this way we ensure that
    -- we don't accidentally access events for devices we don't have access to.
    -- This can only happen if we change the RLS for the events table.
    SELECT array_agg(DISTINCT input.id)
    FROM unnest(filtered_device_ids_org) as input(id)
    WHERE EXISTS
        (SELECT * FROM toit_artemis.events e WHERE input.id = e.device_id)
    INTO filtered_device_ids;

    -- Finally do the actual query.
    -- The query is executed with SECURITY DEFINER.
    RETURN QUERY
      SELECT * FROM toit_artemis.get_events(filtered_device_ids, _types, _limit, _since);
END;
$$;
