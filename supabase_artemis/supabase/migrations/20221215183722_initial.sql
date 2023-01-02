-- Copyright (C) 2022 Toitware ApS. All rights reserved.

-- Create tables.
-- Make sure that tables with foreign keys are created after their foreign tables.

CREATE TABLE public.profiles (
    "id" "uuid" PRIMARY KEY,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "name" character varying NOT NULL,

    CONSTRAINT "profiles_id_fkey"
      FOREIGN KEY ("id")
      REFERENCES auth.users("id")
      ON UPDATE CASCADE
      ON DELETE CASCADE
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.organizations (
    "id" "uuid" DEFAULT extensions.uuid_generate_v4() PRIMARY KEY,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "name" character varying NOT NULL,
    -- We generally don't use the owner field, but it makes it easier to
    -- insert a new organization and still have access to it.
    -- We have a trigger that will create an entry in the roles table, but
    -- that one is not enough to get the organization id when doing an insert.
    "owner_id" "uuid" DEFAULT auth.uid(),

    CONSTRAINT "organizations_owner_fkey"
      FOREIGN KEY ("owner_id")
      REFERENCES public.profiles("id")
      ON UPDATE CASCADE
      ON DELETE SET NULL
);

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;

CREATE TYPE public.role AS ENUM (
    'admin',
    'member'
);

CREATE TABLE public.roles (
    "id" BIGSERIAL PRIMARY KEY,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "role" public.role DEFAULT 'member'::public.role NOT NULL,

    -- Only allow one entry for each org/user combination.
    CONSTRAINT "roles_user_uid_organization_uid_key" UNIQUE ("user_id", "organization_id"),
    CONSTRAINT "roles_organization_id_fkey"
      FOREIGN KEY ("organization_id")
      REFERENCES public.organizations("id")
      ON UPDATE CASCADE
      ON DELETE CASCADE,
    CONSTRAINT "roles_user_id_fkey"
      FOREIGN KEY ("user_id")
      REFERENCES public.profiles("id")
      ON UPDATE CASCADE
      ON DELETE CASCADE
);

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.devices (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() PRIMARY KEY,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "alias" "text" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "organization_id" "uuid",

    CONSTRAINT "devices_organization_id_fkey"
      FOREIGN KEY ("organization_id")
      REFERENCES public.organizations("id")
      ON UPDATE CASCADE
      ON DELETE CASCADE
);

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.events (
    "id" BIGSERIAL PRIMARY KEY,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "device_id" "uuid" NOT NULL,
    "data" "json" NOT NULL,

    CONSTRAINT "devices_id_fkey"
      FOREIGN KEY ("device_id")
      REFERENCES public.devices("id")
      ON UPDATE CASCADE
      ON DELETE CASCADE
);

ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;


-- Trigger Functions
-- Remember that trigger functions are run with the privileges of the user, unless
-- 'SECURITY DEFINER' is used.
-- Trigger functions can't be invoked through RPC calls which provides some security.

CREATE OR REPLACE FUNCTION public.create_profile_for_new_user()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
AS $function$
  DECLARE
    name varchar;
  BEGIN
    name := coalesce(NEW.raw_user_meta_data ->> 'user_name', NEW.email, 'Unknown');

    INSERT INTO public.profiles (id, name) VALUES (NEW.id, name);

    RETURN NEW;
  END;
$function$;

CREATE TRIGGER create_profile_after_new_user AFTER INSERT on auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.create_profile_for_new_user();

CREATE OR REPLACE FUNCTION public.create_admin_for_new_organization()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
AS $function$
  BEGIN
    -- The owner_id should always be set, unless a superuser is creating the organization.
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.roles (user_id, organization_id, role) VALUES (auth.uid(), NEW.id, 'admin');
    END IF;
    RETURN NEW;
  END;
$function$;

CREATE TRIGGER create_admin_after_new_organization AFTER INSERT ON public.organizations
    FOR EACH ROW
    EXECUTE FUNCTION public.create_admin_for_new_organization();

-- Functions
-- Note that this function is defined as SECURITY DEFINER, so it will run with high privileges.
-- Since this isn't a trigger function, it can be invoked through RPC calls.
CREATE FUNCTION is_auth_member_of_org(_organization_id uuid)
  RETURNS boolean
  LANGUAGE sql
  SECURITY DEFINER
  AS $function$
    SELECT EXISTS (
      SELECT 1
      FROM public.roles
      WHERE user_id = auth.uid()
      AND organization_id = _organization_id
    )
  $function$;

CREATE FUNCTION is_auth_admin_of_org(_organization_id uuid)
  RETURNS boolean
  LANGUAGE sql
  SECURITY DEFINER
  AS $function$
    SELECT EXISTS (
      SELECT 1
      FROM public.roles
      WHERE user_id = auth.uid()
      AND organization_id = _organization_id
      AND role = 'admin'
    )
  $function$;

-- Policies
-- Remember that policies are run with the same privileges as the user running the query.

CREATE POLICY "Profile can only be changed by owner"
  ON public.profiles
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Profile can only be seen by owners"
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (auth.uid() = id);

-- Any authenticated user can create a fresh organization.
-- The trigger function (above) will then automatically create an admin role for the user.
CREATE POLICY "Owner can do everything to organization"
  ON public.organizations
  FOR ALL
  TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

CREATE POLICY "Admins can do everything to organization"
  ON public.organizations
  FOR ALL
  TO authenticated
  USING (is_auth_admin_of_org(id));

CREATE POLICY "Members can read organization"
  ON public.organizations
  FOR SELECT
  TO authenticated
  USING (is_auth_member_of_org(id));

CREATE POLICY "Admins can modify roles"
  ON public.roles
  FOR ALL
  TO authenticated
  USING (is_auth_admin_of_org(organization_id))
  WITH CHECK (is_auth_admin_of_org(organization_id));

CREATE POLICY "Users can see members of the orgs they are a member of"
  ON public.roles
  FOR SELECT
  TO authenticated
  USING (is_auth_member_of_org(organization_id));

CREATE POLICY "User must be in org of device"
  ON public.devices
  FOR ALL
  TO authenticated
  USING (is_auth_member_of_org(organization_id))
  WITH CHECK (is_auth_member_of_org(organization_id));

-- The foreign key relation will disallow entries for devices that don't exist.
CREATE POLICY "Enable insert of events to everyone"
  ON public.events
  FOR INSERT
  TO anon
  WITH CHECK (true);

-- The caller could also just change the bearer token to 'anon' but this
-- seems easier.
CREATE POLICY "Enable insert of events to authenticated"
  ON public.events
  FOR INSERT
  TO authenticated
  WITH CHECK (true);
