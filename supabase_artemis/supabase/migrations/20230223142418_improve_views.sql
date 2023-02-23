-- Copyright (C) 2023 Toitware ApS. All rights reserved.

ALTER VIEW admins_profiles
    RENAME TO admin_with_profile;

DROP VIEW roles_with_profile;

-- A view that adds profile information to the roles table.
CREATE OR REPLACE VIEW roles_with_profile
WITH (security_invoker=on)
AS
    -- We expect the profile table to change more than the roles table.
    -- Therefore we use '*' for the profiles table.
    SELECT r.organization_id, o.name organization_name , r.role, p.*
    FROM roles r, organizations o, profiles_with_email p
    WHERE r.user_id = p.id AND r.organization_id = o.id;
