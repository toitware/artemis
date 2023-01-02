-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- Members of the organization can read events.
CREATE POLICY "Organization members can read events"
  ON public.events
  FOR SELECT
  TO authenticated
  USING (
    is_auth_member_of_org(
      (SELECT organization_id FROM devices WHERE devices.id = device_id)
    )
  );
