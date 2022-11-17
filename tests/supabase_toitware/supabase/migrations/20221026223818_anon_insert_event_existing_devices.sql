CREATE POLICY "Enable insert for existing devices"
    ON public.events
    AS PERMISSIVE
    FOR INSERT
    TO anon
    WITH CHECK ((EXISTS ( SELECT 1
   FROM devices
  WHERE (devices.id = events.device))));
