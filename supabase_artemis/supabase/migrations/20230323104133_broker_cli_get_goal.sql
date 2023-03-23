-- Copyright (C) 2023 Toitware ApS. All rights reserved.

SET search_path TO toit_artemis;

-- Returns the goal for a device without creating an event.
CREATE OR REPLACE FUNCTION toit_artemis.get_goal_no_event(_device_id UUID)
RETURNS JSON
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN (SELECT goal FROM toit_artemis.goals WHERE device_id = _device_id);
END;
$$;

SET search_path TO public;

-- Add the forwarding function.
CREATE OR REPLACE FUNCTION public."toit_artemis.get_goal_no_event"(_device_id UUID)
RETURNS JSON
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN (SELECT toit_artemis.get_goal_no_event(_device_id));
END;
$$;


