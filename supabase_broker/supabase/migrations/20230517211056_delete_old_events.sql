-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

-- Use 'toit_artemis' to resolve unqualified variables.
SET search_path TO toit_artemis;

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION toit_artemis.max_event_age()
RETURNS INTERVAL
IMMUTABLE
LANGUAGE SQL
AS $$
    SELECT INTERVAL '30 days';
$$;

-- Delete events that are older than
CREATE OR REPLACE FUNCTION toit_artemis.delete_old_events()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM toit_artemis.events
    WHERE timestamp < NOW() - toit_artemis.max_event_age();
END;
$$;

SELECT cron.schedule (
    'clear-old-events',
    '0 0 * * *', -- Every day at midnight.
    'SELECT toit_artemis.delete_old_events();'
);
