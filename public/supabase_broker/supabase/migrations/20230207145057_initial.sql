-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

CREATE SCHEMA IF NOT EXISTS toit_artemis;
GRANT USAGE ON SCHEMA toit_artemis TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA toit_artemis GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA toit_artemis GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA toit_artemis GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;

SET search_path TO toit_artemis;

-- The devices with their current state.
CREATE TABLE IF NOT EXISTS devices
(
    id uuid NOT NULL PRIMARY KEY,
    state jsonb NOT NULL
);

ALTER TABLE devices ENABLE ROW LEVEL SECURITY;

-- The goal-states for each device.
CREATE TABLE IF NOT EXISTS goals
(
    device_id uuid PRIMARY KEY NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    goal jsonb
);

ALTER TABLE goals ENABLE ROW LEVEL SECURITY;

INSERT INTO storage.buckets (id, name, public)
VALUES ('toit-artemis-assets', 'toit-artemis-assets', true);

-- Informs the broker that a new device was provisioned.
CREATE OR REPLACE FUNCTION new_provisioned(_device_id UUID, _state JSONB)
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO toit_artemis.devices (id, state)
      VALUES (_device_id, _state);
END;
$$;

-- Updates the state of a device.
-- We use a function, so that broker implementations can change the
-- implementation without needing to change the clients.
CREATE OR REPLACE FUNCTION update_state(_device_id UUID, _state JSONB)
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE toit_artemis.devices
      SET state = _state
      WHERE id = _device_id;
END;
$$;

-- Returns the goal for a device.
-- We use a function, so that devices need to know their own id.
CREATE OR REPLACE FUNCTION get_goal(_device_id UUID)
RETURNS JSON
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN (SELECT goal FROM toit_artemis.goals WHERE device_id = _device_id);
END;
$$;

-- Returns the state for a device.
CREATE OR REPLACE FUNCTION get_state(_device_id UUID)
RETURNS JSON
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN (SELECT state FROM toit_artemis.devices WHERE id = _device_id);
END;
$$;

-- Sets the state goal for a device.
CREATE OR REPLACE FUNCTION set_goal(_device_id UUID, _goal JSONB)
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO toit_artemis.goals (device_id, goal)
      VALUES (_device_id, _goal)
      ON CONFLICT (device_id) DO UPDATE
      SET goal = _goal;
END;
$$;

-- Removes a device.
CREATE OR REPLACE FUNCTION remove_device(_device_id UUID)
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM toit_artemis.devices WHERE id = _device_id;
END;
$$;
