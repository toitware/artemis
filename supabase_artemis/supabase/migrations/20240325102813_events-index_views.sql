-- Copyright (C) 2024 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

CREATE INDEX IF NOT EXISTS events_device_id_created_at_idx
    ON public.events (device_id, created_at DESC);

CREATE OR REPLACE VIEW public.organization_admins
WITH (security_invoker=on)
AS
    SELECT o.id, o.name, r.name as admin, u.email
    FROM public.organizations o
    LEFT JOIN public.roles_with_profile r
        ON r.organization_id = o.id
    JOIN auth.users u
        ON u.id = r.id
    WHERE r.role = 'admin'
    GROUP BY o.id, o.name, r.name, u.email
    ORDER BY o.name;

CREATE OR REPLACE VIEW public.active_devices
WITH (security_invoker=on)
AS
    WITH
        max_created_events AS (
            SELECT device_id,
            MAX(created_at) AS max_created_at
            FROM public.events
            WHERE created_at >= DATE_TRUNC('month', current_date)
            GROUP BY device_id
        ),
        min_created_events AS (
            SELECT device_id,
            MIN(created_at) AS min_created_at
            FROM public.events
            WHERE
                device_id IN (
                    SELECT device_id
                    FROM max_created_events
                )
            GROUP BY device_id
        )
    SELECT
        o.name AS organization_name,
        COUNT(DISTINCT e.device_id) AS device_count
    FROM public.events e
    JOIN max_created_events mce ON e.device_id = mce.device_id
            AND e.created_at = mce.max_created_at
    JOIN min_created_events mne ON e.device_id = mne.device_id
    JOIN public.devices d ON e.device_id = d.id
    JOIN public.organizations o ON d.organization_id = o.id
    WHERE
        mce.max_created_at - mne.min_created_at >= interval '31 days'
    GROUP BY o.name
    ORDER BY o.name;
