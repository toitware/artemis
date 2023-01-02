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
