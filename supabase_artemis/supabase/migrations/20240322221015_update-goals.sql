-- Copyright (C) 2024 Toitware ApS. All rights reserved.

CREATE OR REPLACE FUNCTION toit_artemis.set_goals(_device_ids UUID[], _goals JSONB[])
RETURNS void
SECURITY INVOKER
LANGUAGE "plpgsql"
AS $$
BEGIN
    FOR i IN 1..array_length(_device_ids, 1) LOOP
        INSERT INTO toit_artemis.goals (device_id, goal)
          VALUES (_device_ids[i], _goals[i])
          ON CONFLICT (device_id) DO UPDATE
          SET goal = _goals[i];
    END LOOP;
END;
$$;
