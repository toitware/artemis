-- Copyright (C) 2023 Toitware ApS. All rights reserved.

CREATE TABLE IF NOT EXISTS public.devices
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    config json DEFAULT NULL,
    CONSTRAINT devices_pkey PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS public.reports
(
    id SERIAL PRIMARY KEY,
    device_id uuid NOT NULL,
    status json,
    CONSTRAINT reports_device_id_fkey FOREIGN KEY (device_id)
        REFERENCES public.devices (id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
);

insert into storage.buckets (id, name, public)
values ('assets', 'assets', true);

create policy "Public Access"
  on storage.objects for all
  using (bucket_id = 'assets');

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
