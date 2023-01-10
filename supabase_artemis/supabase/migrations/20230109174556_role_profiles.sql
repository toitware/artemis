-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- A view that adds profile information to the roles table.
CREATE OR REPLACE VIEW roles_with_profile
WITH (security_invoker=on)
AS
  -- We expect profiles to change more than the roles table.
  -- Therefore we use '*' for the profiles table.
  SELECT r.organization_id, r.role, p.*
  FROM roles r, profiles_with_email p
  WHERE r.user_id = p.id;

CREATE POLICY "Users can remove themselves from an organization"
  ON public.roles
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());
