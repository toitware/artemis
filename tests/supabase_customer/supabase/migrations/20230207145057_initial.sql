-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- The devices with their current state.
CREATE TABLE IF NOT EXISTS public.devices
(
    id uuid NOT NULL PRIMARY KEY,
    state jsonb NOT NULL
);

-- The goal-states for each device.
CREATE TABLE IF NOT EXISTS public.goals
(
    device_id uuid PRIMARY KEY NOT NULL REFERENCES public.devices (id) ON DELETE CASCADE,
    goal jsonb
);

insert into storage.buckets (id, name, public)
values ('assets', 'assets', true);

create policy "Public Access"
  on storage.objects for all
  using (bucket_id = 'assets');

-- Informs the broker that a new device was provisioned.
CREATE OR REPLACE FUNCTION new_provisioned(_device_id UUID, _state JSONB)
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO devices (id, state)
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
    UPDATE devices
      SET state = _state
      WHERE id = _device_id;
END;
$$;

-- Returns the goal for a device.
-- We use a function, so that devices need to know their own id.
CREATE OR REPLACE FUNCTION get_goal(_device_id UUID)
RETURNS JSONB
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN (SELECT goal FROM goals WHERE device_id = _device_id);
END;
$$;
