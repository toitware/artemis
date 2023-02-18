-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- Typical permissions for the Toit Artemis DB.

-- All devices can get their goal without authentication.
-- Note that they still need to provide the device ID. As such, this is not
-- a security hole.
ALTER FUNCTION toit_artemis.get_goal SECURITY DEFINER;

-- All devices can update their state without authentication.
-- Note that they still need to provide the device ID. As such, this is not
-- a security hole.
ALTER FUNCTION toit_artemis.update_state SECURITY DEFINER;

-- Give authenticated users access to the functions and to the storage.
CREATE POLICY "Authenticated have full access to devices table"
  ON toit_artemis.devices
  FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated have full access to goals table"
  ON toit_artemis.goals
  FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated have full access to storage"
  ON storage.objects
  FOR ALL
  TO authenticated
  USING (bucket_id = 'toit-artemis-assets')
  WITH CHECK (bucket_id = 'toit-artemis-assets');
