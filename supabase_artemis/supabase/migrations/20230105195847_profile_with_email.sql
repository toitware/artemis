-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- Whether the authenticated user is a member of the same organization as _id.
CREATE OR REPLACE FUNCTION is_auth_in_same_org_as(_id UUID)
RETURNS BOOLEAN
SECURITY DEFINER
AS $$
BEGIN
  RETURN (
    EXISTS (
      SELECT 1
      FROM roles
      WHERE roles.user_id = auth.uid()
        AND roles.organization_id IN (
          SELECT organization_id FROM roles WHERE roles.user_id = _id
        )
    )
  );
END;
$$ LANGUAGE plpgsql;

-- Gets the email of a user with the given id.
-- This function does run with the privileges of the definer.
-- We protect against email leaking by verifying that the authenticated user
-- and the user with the given id are members of the same organization.
CREATE OR REPLACE FUNCTION email_for_id(_id UUID)
RETURNS TEXT
SECURITY DEFINER
AS $$
BEGIN
  RETURN (
    SELECT email
    FROM auth.users
    WHERE auth.users.id = _id AND (_id = auth.uid() OR is_auth_in_same_org_as(_id))
  );
END;
$$ LANGUAGE plpgsql;

-- Profiles can be seen by members of the same organization.
CREATE POLICY "Organization members can read profiles"
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (is_auth_in_same_org_as(id));

-- A view that adds email to the profiles table.
CREATE OR REPLACE VIEW profiles_with_email
WITH (security_invoker=on)
AS
  SELECT p.*, email_for_id(p.id) as email
  FROM profiles p;
