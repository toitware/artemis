-- Copyright (C) 2023 Toitware ApS. All rights reserved.

SET search_path TO toit_artemis;

-- Returns the goal for a device.
-- We use a function, so that devices need to know their own id.
CREATE OR REPLACE FUNCTION toit_artemis.get_goal(_device_id UUID)
RETURNS JSON
SECURITY DEFINER  -- Allows devices to get goals without authentication.
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM toit_artemis.report_event(_device_id, 'get_goal', 'null'::JSONB);
    RETURN (SELECT goal FROM toit_artemis.goals WHERE device_id = _device_id);
END;
$$;

-- Updates the state of a device.
-- We use a function, so that broker implementations can change the
-- implementation without needing to change the clients.
CREATE OR REPLACE FUNCTION toit_artemis.update_state(_device_id UUID, _state JSONB)
RETURNS VOID
SECURITY DEFINER  -- Allows devices to update their own state without authentication.
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM toit_artemis.report_event(_device_id, 'update-state', _state);
    UPDATE toit_artemis.devices
      SET state = _state
      WHERE id = _device_id;
END;
$$;
