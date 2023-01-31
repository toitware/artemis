-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- If a device reports its status but isn't yet in the devices list
-- we add it with "NULL" as config.
CREATE OR REPLACE FUNCTION report_status(_device_id UUID, _status JSON)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO devices (id, config)
      VALUES (_device_id, NULL)
      ON CONFLICT DO NOTHING;
    INSERT INTO reports (device_id, status)
      VALUES (_device_id, _status);
END;
$$;
