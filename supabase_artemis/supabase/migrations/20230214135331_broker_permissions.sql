-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- Permissions for the Toit Artemis DB.

-- The provision device entries must reference devices in the public devices table.
ALTER TABLE toit_artemis.devices
  ADD CONSTRAINT fk_id FOREIGN KEY (id) REFERENCES public.devices (id)
  ON DELETE CASCADE;

-- All devices can get their goal without authentication.
-- Note that they still need to provide the device ID. As such, this is not
-- a big security hole.
ALTER FUNCTION toit_artemis.get_goal SECURITY DEFINER;

-- All devices can update their state without authentication.
-- Note that they still need to provide the device ID. As such, this is not
-- a big security hole.
ALTER FUNCTION toit_artemis.update_state SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_auth_in_org_of_device(_device_id UUID)
  RETURNS BOOLEAN
  SECURITY DEFINER
  LANGUAGE plpgsql
  AS $$
BEGIN
  RETURN is_auth_member_of_org(
    (SELECT organization_id FROM public.devices WHERE id = _device_id)
  );
END;
$$;

-- Give authenticated users access to the functions and to the storage.
CREATE POLICY "Authenticated have full access to devices of the orgs they are member in"
  ON toit_artemis.devices
  FOR ALL
  TO authenticated
  USING (is_auth_in_org_of_device(id))
  WITH CHECK (is_auth_in_org_of_device(id));

CREATE POLICY "Authenticated have full access to goals table of devices of the orgs they are member in"
  ON toit_artemis.goals
  FOR ALL
  TO authenticated
  USING (is_auth_in_org_of_device(device_id))
  WITH CHECK (is_auth_in_org_of_device(device_id));

CREATE POLICY "Authenticated have full access to storage in their orgs"
  ON storage.objects
  FOR ALL
  TO authenticated
  USING (
    bucket_id = 'toit-artemis-assets' AND
    is_auth_member_of_org((storage.foldername(name))[1]::uuid)
  )
  WITH CHECK (
    bucket_id = 'toit-artemis-assets' AND
    is_auth_member_of_org((storage.foldername(name))[1]::uuid)
  );
