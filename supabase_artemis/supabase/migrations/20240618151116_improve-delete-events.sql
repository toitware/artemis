-- Copyright (C) 2024 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

DROP FUNCTION toit_artemis.max_event_age;
SELECT cron.unschedule('clear-old-events');

CREATE OR REPLACE FUNCTION toit_artemis.min_event_age()
RETURNS INTERVAL
IMMUTABLE
LANGUAGE SQL
AS $$
    SELECT INTERVAL '3 days';
$$;

CREATE OR REPLACE FUNCTION toit_artemis.max_events()
RETURNS INTEGER
IMMUTABLE
LANGUAGE SQL
AS $$
    SELECT 128;
$$;

-- Remove old events.
-- We keep the ones that aren't old enough yet, and a certain number otherwise.
CREATE OR REPLACE FUNCTION toit_artemis.delete_old_events()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM toit_artemis.events
    WHERE timestamp < NOW() - toit_artemis.max_event_age();
END;
$$;
CREATE OR REPLACE FUNCTION toit_artemis.delete_old_events()
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  device RECORD;
  oldest_timestamp TIMESTAMP;
BEGIN
  -- Loop through each unique device_id in the events table.
  FOR device IN SELECT DISTINCT device_id FROM toit_artemis.events LOOP
    -- Find the timestamp of the max-events()'th most recent event for this device_id.
    SELECT timestamp INTO oldest_timestamp
    FROM toit_artemis.events
    WHERE device_id = device.device_id
    ORDER BY timestamp DESC
    OFFSET toit_artemis.max_events() LIMIT 1;

    -- If there aren't enough items, skip deletion.
    IF FOUND THEN
      -- Delete all events for this device_id older than the found timestamp
      -- but keep events that are younger than the min_event_age().
      DELETE FROM toit_artemis.events
        WHERE device_id = device.device_id
        AND timestamp < LEAST(oldest_timestamp, NOW() - toit_artemis.min_event_age());
    END IF;
  END LOOP;
END $$;

SELECT cron.schedule (
    'clear-old-events',
    '0 0 * * *', -- Every day at midnight.
    'SELECT toit_artemis.delete_old_events();'
);
