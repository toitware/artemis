-- Copyright (C) 2024 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

REVOKE ALL PRIVILEGES
  ON public.admin_with_profile
  FROM anon, authenticated;

REVOKE ALL PRIVILEGES
  ON public.organization_admins
  FROM anon, authenticated;

