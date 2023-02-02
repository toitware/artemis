-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- Informs the broker that a new device was provisioned.
CREATE OR REPLACE FUNCTION new_provisioned(_device_id UUID)
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO devices (id, config)
      VALUES (_device_id, NULL)
      ON CONFLICT DO NOTHING;
END;
$$;
