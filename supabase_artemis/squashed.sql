

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE SCHEMA IF NOT EXISTS "toit_artemis";


ALTER SCHEMA "toit_artemis" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."role" AS ENUM (
    'admin',
    'member'
);


ALTER TYPE "public"."role" OWNER TO "postgres";


CREATE TYPE "toit_artemis"."pod" AS (
	"id" "uuid",
	"pod_description_id" bigint,
	"revision" integer,
	"created_at" timestamp with time zone,
	"tags" "text"[]
);


ALTER TYPE "toit_artemis"."pod" OWNER TO "postgres";


CREATE TYPE "toit_artemis"."poddescription" AS (
	"id" bigint,
	"name" "text",
	"description" "text"
);


ALTER TYPE "toit_artemis"."poddescription" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_admin_for_new_organization"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
  BEGIN
    -- The owner_id should always be set, unless a superuser is creating the organization.
    IF auth.uid() IS NOT NULL THEN
      INSERT INTO public.roles (user_id, organization_id, role) VALUES (auth.uid(), NEW.id, 'admin');
    END IF;
    RETURN NEW;
  END;
$$;


ALTER FUNCTION "public"."create_admin_for_new_organization"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_profile_for_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
  DECLARE
    name varchar;
  BEGIN
    name := coalesce(NEW.raw_user_meta_data ->> 'user_name', NEW.email, 'Unknown');

    INSERT INTO public.profiles (id, name) VALUES (NEW.id, name);

    RETURN NEW;
  END;
$$;


ALTER FUNCTION "public"."create_profile_for_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."email_for_id"("_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN (
    SELECT email
    FROM auth.users
    WHERE auth.users.id = _id AND (_id = auth.uid() OR is_auth_in_same_org_as(_id))
  );
END;
$$;


ALTER FUNCTION "public"."email_for_id"("_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_artemis_admin"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM admins WHERE id = auth.uid());
END;
$$;


ALTER FUNCTION "public"."is_artemis_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_auth_admin_of_org"("_organization_id" "uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
    SELECT EXISTS (
      SELECT 1
      FROM public.roles
      WHERE user_id = auth.uid()
      AND organization_id = _organization_id
      AND role = 'admin'
    )
  $$;


ALTER FUNCTION "public"."is_auth_admin_of_org"("_organization_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_auth_in_org_of_alias"("_device_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN is_auth_member_of_org(
    (SELECT organization_id FROM public.devices WHERE alias = _device_id)
  );
END;
$$;


ALTER FUNCTION "public"."is_auth_in_org_of_alias"("_device_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_auth_in_same_org_as"("_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
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
$$;


ALTER FUNCTION "public"."is_auth_in_same_org_as"("_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_auth_member_of_org"("_organization_id" "uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
    SELECT EXISTS (
      SELECT 1
      FROM public.roles
      WHERE user_id = auth.uid()
      AND organization_id = _organization_id
    )
  $$;


ALTER FUNCTION "public"."is_auth_member_of_org"("_organization_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_devices"("_device_ids" "uuid"[]) RETURNS TABLE("device_id" "uuid", "goal" "jsonb", "state" "jsonb")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
      SELECT * FROM toit_artemis.get_devices(_device_ids);
END;
$$;


ALTER FUNCTION "public"."toit_artemis.get_devices"("_device_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone DEFAULT '1970-01-01 00:00:00+00'::timestamp with time zone) RETURNS TABLE("device_id" "uuid", "type" "text", "ts" timestamp with time zone, "data" "jsonb")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
      SELECT * FROM toit_artemis.get_events(_device_ids, _types, _limit, _since);
END;
$$;


ALTER FUNCTION "public"."toit_artemis.get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."delete_old_events"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM toit_artemis.events
    WHERE timestamp < NOW() - toit_artemis.max_event_age();
END;
$$;


ALTER FUNCTION "toit_artemis"."delete_old_events"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _pod_description_id BIGINT;
BEGIN
    FOR _pod_description_id IN SELECT unnest(_description_ids) LOOP
        DELETE FROM toit_artemis.pod_descriptions WHERE id = _pod_description_id AND fleet_id = _fleet_id;
    END LOOP;
END;
$$;


ALTER FUNCTION "toit_artemis"."delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM toit_artemis.pod_tags
    WHERE pod_description_id = _pod_description_id
        AND tag = _tag;
END;
$$;


ALTER FUNCTION "toit_artemis"."delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _pod_id UUID;
BEGIN
    FOR _pod_id IN SELECT unnest(_pod_ids) LOOP
        DELETE FROM toit_artemis.pods WHERE id = _pod_id AND fleet_id = _fleet_id;
    END LOOP;
END;
$$;


ALTER FUNCTION "toit_artemis"."delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_devices"("_device_ids" "uuid"[]) RETURNS TABLE("device_id" "uuid", "goal" "jsonb", "state" "jsonb")
    LANGUAGE "plpgsql"
    AS $_$
DECLARE filtered_device_ids UUID[];
BEGIN
    -- Using EXECUTE to prevent Postgres from caching a generic query plan.
    -- A generic plan would use Sequential Scans over the RLS policy, timing out.
    EXECUTE '
        SELECT array_agg(DISTINCT d.id)
        FROM unnest($1) as input(id)
        JOIN toit_artemis.devices d ON input.id = d.id
    ' INTO filtered_device_ids USING _device_ids;

    RETURN QUERY EXECUTE '
        SELECT p.device_id, g.goal, d.state
        FROM unnest($1) AS p(device_id)
        LEFT JOIN toit_artemis.goals g USING (device_id)
        LEFT JOIN toit_artemis.devices d ON p.device_id = d.id
    ' USING filtered_device_ids;
END;
$_$;


ALTER FUNCTION "toit_artemis"."get_devices"("_device_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone DEFAULT '1970-01-01 00:00:00+00'::timestamp with time zone) RETURNS TABLE("device_id" "uuid", "type" "text", "ts" timestamp with time zone, "data" "jsonb")
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
    _type TEXT;
    filtered_device_ids UUID[];
BEGIN
    -- Using EXECUTE to prevent generic plan caching and forced sequential scans.
    EXECUTE '
        SELECT array_agg(DISTINCT d.id)
        FROM unnest($1) as input(id)
        JOIN toit_artemis.devices d ON input.id = d.id
    ' INTO filtered_device_ids USING _device_ids;

    IF ARRAY_LENGTH(_types, 1) = 1 THEN
        _type := _types[1];
        RETURN QUERY EXECUTE '
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest($1) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.type = $2
                        AND e.timestamp >= $3
                ORDER BY e.timestamp DESC
                LIMIT $4
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC
        ' USING filtered_device_ids, _type, _since, _limit;
    ELSEIF ARRAY_LENGTH(_types, 1) > 1 THEN
        RETURN QUERY EXECUTE '
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest($1) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.type = ANY($2)
                        AND e.timestamp >= $3
                ORDER BY e.timestamp DESC
                LIMIT $4
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC
        ' USING filtered_device_ids, _types, _since, _limit;
    ELSE
        -- Note that 'ARRAY_LENGTH' of an empty array does not return 0 but null.
        RETURN QUERY EXECUTE '
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest($1) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.timestamp >= $2
                ORDER BY e.timestamp DESC
                LIMIT $3
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC
        ' USING filtered_device_ids, _since, _limit;
    END IF;
END;
$_$;


ALTER FUNCTION "toit_artemis"."get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_goal"("_device_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    PERFORM toit_artemis.report_event(_device_id, 'get-goal', 'null'::JSONB);
    RETURN (SELECT goal FROM toit_artemis.goals WHERE device_id = _device_id);
END;
$$;


ALTER FUNCTION "toit_artemis"."get_goal"("_device_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_goal_no_event"("_device_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN (SELECT goal FROM toit_artemis.goals WHERE device_id = _device_id);
END;
$$;


ALTER FUNCTION "toit_artemis"."get_goal_no_event"("_device_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_pod_descriptions"("_fleet_id" "uuid") RETURNS SETOF "toit_artemis"."poddescription"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    description_ids BIGINT[];
BEGIN
    -- Store the relevant ids in a temporary array.
    description_ids := ARRAY(
        SELECT pd.id
        FROM toit_artemis.pod_descriptions pd
        WHERE pd.fleet_id = _fleet_id
        ORDER BY pd.id DESC
    );

    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_ids(description_ids);
END;
$$;


ALTER FUNCTION "toit_artemis"."get_pod_descriptions"("_fleet_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_pod_descriptions_by_ids"("_description_ids" bigint[]) RETURNS SETOF "toit_artemis"."poddescription"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
        SELECT pd.id, pd.name, pd.description
        FROM toit_artemis.pod_descriptions pd
        WHERE pd.id = ANY(_description_ids);
END;
$$;


ALTER FUNCTION "toit_artemis"."get_pod_descriptions_by_ids"("_description_ids" bigint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) RETURNS SETOF "toit_artemis"."poddescription"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    i INTEGER := 1;
    name_exists BOOLEAN;
    description_ids BIGINT[];
BEGIN
    IF _create_if_absent THEN
        WHILE i <= array_length(_names, 1) LOOP
            -- Check if the name already exists.
            SELECT EXISTS(
                    SELECT 1
                    FROM toit_artemis.pod_descriptions pd
                    WHERE pd.fleet_id = _fleet_id
                        AND pd.name = _names[i]
                )
                INTO name_exists
                FOR UPDATE;  -- Lock the rows so concurrent updates don't duplicate the name.

            IF NOT name_exists THEN
                -- Create the pod description.
                PERFORM toit_artemis.upsert_pod_description(
                        _fleet_id,
                        _organization_id,
                        _names[i],
                        NULL
                    );
            END IF;

            i := i + 1;
        END LOOP;
    END IF;

    -- Store the relevant ids in a temporary array.
    description_ids := ARRAY(
        SELECT pd.id
        FROM toit_artemis.pod_descriptions pd
        WHERE pd.fleet_id = _fleet_id
            AND pd.name = ANY(_names)
    );

    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_ids(description_ids);
END;
$$;


ALTER FUNCTION "toit_artemis"."get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) RETURNS SETOF "toit_artemis"."pod"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _pod_ids UUID[];
    _fleet_id UUID;
BEGIN
    SELECT ARRAY(
        SELECT p.id
        FROM toit_artemis.pods p
        WHERE p.pod_description_id = _pod_description_id
        ORDER BY p.created_at DESC
        LIMIT _limit
        OFFSET _offset
    )
    INTO _pod_ids;

    SELECT fleet_id
    FROM toit_artemis.pod_descriptions
    WHERE id = _pod_description_id
    INTO _fleet_id;

    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods_by_ids(_fleet_id, _pod_ids);
END;
$$;


ALTER FUNCTION "toit_artemis"."get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) RETURNS SETOF "toit_artemis"."pod"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
        SELECT p.id, p.pod_description_id, p.revision, p.created_at,
            CASE
                WHEN pt.pod_id IS NULL
                THEN ARRAY[]::text[]
                ELSE array_agg(pt.tag)
            END
        FROM toit_artemis.pods p
        JOIN toit_artemis.pod_descriptions pd
            ON pd.id = p.pod_description_id
            AND pd.fleet_id = _fleet_id
        LEFT JOIN toit_artemis.pod_tags pt
            ON pt.pod_id = p.id
            AND pt.fleet_id = _fleet_id
            AND pt.pod_description_id = p.pod_description_id
        WHERE
            p.id = ANY(_pod_ids)
            AND p.fleet_id = _fleet_id
        GROUP BY p.id, p.revision, p.created_at, p.pod_description_id, pt.pod_id
        ORDER BY p.created_at DESC;
END;
$$;


ALTER FUNCTION "toit_artemis"."get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") RETURNS TABLE("pod_id" "uuid", "name" "text", "revision" integer, "tag" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
        SELECT p.id, ref.name, ref.revision, ref.tag
        FROM jsonb_to_recordset(_references) as ref(name TEXT, tag TEXT, revision INT)
        JOIN toit_artemis.pod_descriptions pd
            ON pd.name = ref.name
            AND pd.fleet_id = _fleet_id
        LEFT JOIN toit_artemis.pod_tags pt
            ON pt.pod_description_id = pd.id
            AND pt.fleet_id = _fleet_id
            AND pt.tag = ref.tag
        JOIN toit_artemis.pods p
            ON p.pod_description_id = pd.id
            AND p.fleet_id = _fleet_id
            -- If we found a tag, then we match by id here.
            -- Otherwise we match by revision.
            -- If neither works we don't match and due to the inner join drop the row.
            AND (p.id = pt.pod_id OR p.revision = ref.revision);
END;
$$;


ALTER FUNCTION "toit_artemis"."get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."get_state"("_device_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN (SELECT state FROM toit_artemis.devices WHERE id = _device_id);
END;
$$;


ALTER FUNCTION "toit_artemis"."get_state"("_device_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _revision INT;
    _fleet_id UUID;
BEGIN
    -- Lock the pod_description_id row so concurrent updates don't duplicate the revision.
    PERFORM * FROM toit_artemis.pod_descriptions
        WHERE id = _pod_description_id
        FOR UPDATE;

    -- Get a new revision for the pod.
    -- Max + 1 of the existing revisions for this pod_description_id.
    SELECT COALESCE(MAX(revision), 0) + 1
        FROM toit_artemis.pods
        WHERE pod_description_id = _pod_description_id
        INTO _revision;

    SELECT fleet_id
        FROM toit_artemis.pod_descriptions
        WHERE id = _pod_description_id
        INTO _fleet_id;

    INSERT INTO toit_artemis.pods (id, fleet_id, pod_description_id, revision)
        VALUES (_pod_id, _fleet_id, _pod_description_id, _revision);
END;
$$;


ALTER FUNCTION "toit_artemis"."insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."max_event_age"() RETURNS interval
    LANGUAGE "sql" IMMUTABLE
    AS $$
    SELECT INTERVAL '30 days';
$$;


ALTER FUNCTION "toit_artemis"."max_event_age"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."new_provisioned"("_device_id" "uuid", "_state" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    INSERT INTO toit_artemis.devices (id, state)
      VALUES (_device_id, _state);
END;
$$;


ALTER FUNCTION "toit_artemis"."new_provisioned"("_device_id" "uuid", "_state" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."remove_device"("_device_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM toit_artemis.devices WHERE id = _device_id;
END;
$$;


ALTER FUNCTION "toit_artemis"."remove_device"("_device_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    INSERT INTO toit_artemis.events (device_id, type, data)
      VALUES (_device_id, _type, _data);
END;
$$;


ALTER FUNCTION "toit_artemis"."report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."set_goal"("_device_id" "uuid", "_goal" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    INSERT INTO toit_artemis.goals (device_id, goal)
      VALUES (_device_id, _goal)
      ON CONFLICT (device_id) DO UPDATE
      SET goal = _goal;
END;
$$;


ALTER FUNCTION "toit_artemis"."set_goal"("_device_id" "uuid", "_goal" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."set_goals"("_device_ids" "uuid"[], "_goals" "jsonb"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    FOR i IN 1..array_length(_device_ids, 1) LOOP
        INSERT INTO toit_artemis.goals (device_id, goal)
          VALUES (_device_ids[i], _goals[i])
          ON CONFLICT (device_id) DO UPDATE
          SET goal = _goals[i];
    END LOOP;
END;
$$;


ALTER FUNCTION "toit_artemis"."set_goals"("_device_ids" "uuid"[], "_goals" "jsonb"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF _force THEN
        -- We could also use an `ON CONFLICT` clause, but this seems easier.
        PERFORM * FROM toit_artemis.pod_tags
            WHERE pod_description_id = _pod_description_id
            AND tag = _tag
            FOR UPDATE; -- Lock the row to prevent concurrent updates.

        DELETE FROM toit_artemis.pod_tags
            WHERE pod_description_id = _pod_description_id
            AND tag = _tag;
    END IF;

    INSERT INTO toit_artemis.pod_tags (pod_id, fleet_id, pod_description_id, tag)
        SELECT _pod_id, pd.fleet_id, _pod_description_id, _tag
        FROM toit_artemis.pod_descriptions pd
        WHERE pd.id = _pod_description_id;
END;
$$;


ALTER FUNCTION "toit_artemis"."set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."update_state"("_device_id" "uuid", "_state" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    PERFORM toit_artemis.report_event(_device_id, 'update-state', _state);
    UPDATE toit_artemis.devices
      SET state = _state
      WHERE id = _device_id;
END;
$$;


ALTER FUNCTION "toit_artemis"."update_state"("_device_id" "uuid", "_state" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "toit_artemis"."upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    pod_description_id BIGINT;
BEGIN
    INSERT INTO toit_artemis.pod_descriptions (fleet_id, organization_id, name, description)
        VALUES (_fleet_id, _organization_id, _name, _description)
        ON CONFLICT (fleet_id, name)
        DO UPDATE SET description = _description
        RETURNING id
        INTO pod_description_id;
    RETURN pod_description_id;
END;
$$;


ALTER FUNCTION "toit_artemis"."upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."devices" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "alias" "uuid" DEFAULT "extensions"."uuid_generate_v4"(),
    "organization_id" "uuid"
);


ALTER TABLE "public"."devices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "device_id" "uuid" NOT NULL,
    "data" "jsonb" NOT NULL
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."organizations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "name" character varying NOT NULL,
    "owner_id" "uuid" DEFAULT "auth"."uid"()
);


ALTER TABLE "public"."organizations" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."active_devices" WITH ("security_invoker"='on') AS
 WITH "max_created_events" AS (
         SELECT "events"."device_id",
            "max"("events"."created_at") AS "max_created_at"
           FROM "public"."events"
          WHERE ("events"."created_at" >= "date_trunc"('month'::"text", (CURRENT_DATE)::timestamp with time zone))
          GROUP BY "events"."device_id"
        ), "min_created_events" AS (
         SELECT "events"."device_id",
            "min"("events"."created_at") AS "min_created_at"
           FROM "public"."events"
          WHERE ("events"."device_id" IN ( SELECT "max_created_events"."device_id"
                   FROM "max_created_events"))
          GROUP BY "events"."device_id"
        )
 SELECT "o"."name" AS "organization_name",
    "count"(DISTINCT "e"."device_id") AS "device_count"
   FROM (((("public"."events" "e"
     JOIN "max_created_events" "mce" ON ((("e"."device_id" = "mce"."device_id") AND ("e"."created_at" = "mce"."max_created_at"))))
     JOIN "min_created_events" "mne" ON (("e"."device_id" = "mne"."device_id")))
     JOIN "public"."devices" "d" ON (("e"."device_id" = "d"."id")))
     JOIN "public"."organizations" "o" ON (("d"."organization_id" = "o"."id")))
  WHERE (("mce"."max_created_at" - "mne"."min_created_at") >= '31 days'::interval)
  GROUP BY "o"."name"
  ORDER BY "o"."name";


ALTER TABLE "public"."active_devices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admins" (
    "id" "uuid" NOT NULL
);


ALTER TABLE "public"."admins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "name" character varying NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."admin_with_profile" WITH ("security_invoker"='on') AS
 SELECT "p"."id",
    "p"."created_at",
    "p"."name",
    "u"."email"
   FROM "public"."admins" "a",
    "public"."profiles" "p",
    "auth"."users" "u"
  WHERE (("a"."id" = "p"."id") AND ("a"."id" = "u"."id"));


ALTER TABLE "public"."admin_with_profile" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."artemis_services" (
    "id" bigint NOT NULL,
    "version" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."artemis_services" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."artemis_services_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."artemis_services_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."artemis_services_id_seq" OWNED BY "public"."artemis_services"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."events_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."events_id_seq" OWNED BY "public"."events"."id";



CREATE OR REPLACE VIEW "public"."profiles_with_email" WITH ("security_invoker"='on') AS
 SELECT "p"."id",
    "p"."created_at",
    "p"."name",
    "public"."email_for_id"("p"."id") AS "email"
   FROM "public"."profiles" "p";


ALTER TABLE "public"."profiles_with_email" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "role" "public"."role" DEFAULT 'member'::"public"."role" NOT NULL
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."roles_with_profile" WITH ("security_invoker"='on') AS
 SELECT "r"."organization_id",
    "o"."name" AS "organization_name",
    "r"."role",
    "p"."id",
    "p"."created_at",
    "p"."name",
    "p"."email"
   FROM "public"."roles" "r",
    "public"."organizations" "o",
    "public"."profiles_with_email" "p"
  WHERE (("r"."user_id" = "p"."id") AND ("r"."organization_id" = "o"."id"));


ALTER TABLE "public"."roles_with_profile" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."organization_admins" WITH ("security_invoker"='on') AS
 SELECT "o"."id",
    "o"."name",
    "r"."name" AS "admin",
    "u"."email"
   FROM (("public"."organizations" "o"
     LEFT JOIN "public"."roles_with_profile" "r" ON (("r"."organization_id" = "o"."id")))
     JOIN "auth"."users" "u" ON (("u"."id" = "r"."id")))
  WHERE ("r"."role" = 'admin'::"public"."role")
  GROUP BY "o"."id", "o"."name", "r"."name", "u"."email"
  ORDER BY "o"."name";


ALTER TABLE "public"."organization_admins" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."roles_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."roles_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."roles_id_seq" OWNED BY "public"."roles"."id";



CREATE TABLE IF NOT EXISTS "public"."sdks" (
    "id" bigint NOT NULL,
    "version" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sdks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."service_images" (
    "id" bigint NOT NULL,
    "sdk_id" bigint NOT NULL,
    "service_id" bigint NOT NULL,
    "image" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "organization_id" "uuid"
);


ALTER TABLE "public"."service_images" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."sdk_service_versions" WITH ("security_invoker"='on') AS
 SELECT "sdks"."version" AS "sdk_version",
    "artemis_services"."version" AS "service_version",
    "i"."organization_id",
    "i"."image"
   FROM "public"."sdks",
    "public"."artemis_services",
    "public"."service_images" "i"
  WHERE (("sdks"."id" = "i"."sdk_id") AND ("artemis_services"."id" = "i"."service_id"));


ALTER TABLE "public"."sdk_service_versions" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."sdks_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."sdks_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sdks_id_seq" OWNED BY "public"."sdks"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."service_images_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."service_images_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."service_images_id_seq" OWNED BY "public"."service_images"."id";



CREATE TABLE IF NOT EXISTS "toit_artemis"."devices" (
    "id" "uuid" NOT NULL,
    "state" "jsonb" NOT NULL
);


ALTER TABLE "toit_artemis"."devices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "toit_artemis"."events" (
    "id" integer NOT NULL,
    "device_id" "uuid" NOT NULL,
    "timestamp" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type" "text" NOT NULL,
    "data" "jsonb" NOT NULL
);


ALTER TABLE "toit_artemis"."events" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "toit_artemis"."events_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "toit_artemis"."events_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "toit_artemis"."events_id_seq" OWNED BY "toit_artemis"."events"."id";



CREATE TABLE IF NOT EXISTS "toit_artemis"."goals" (
    "device_id" "uuid" NOT NULL,
    "goal" "jsonb"
);


ALTER TABLE "toit_artemis"."goals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "toit_artemis"."pod_descriptions" (
    "id" bigint NOT NULL,
    "fleet_id" "uuid" NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "toit_artemis"."pod_descriptions" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "toit_artemis"."pod_descriptions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "toit_artemis"."pod_descriptions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "toit_artemis"."pod_descriptions_id_seq" OWNED BY "toit_artemis"."pod_descriptions"."id";



CREATE TABLE IF NOT EXISTS "toit_artemis"."pod_tags" (
    "id" bigint NOT NULL,
    "pod_id" "uuid" NOT NULL,
    "fleet_id" "uuid" NOT NULL,
    "pod_description_id" bigint NOT NULL,
    "tag" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "toit_artemis"."pod_tags" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "toit_artemis"."pod_tags_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "toit_artemis"."pod_tags_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "toit_artemis"."pod_tags_id_seq" OWNED BY "toit_artemis"."pod_tags"."id";



CREATE TABLE IF NOT EXISTS "toit_artemis"."pods" (
    "id" "uuid" NOT NULL,
    "fleet_id" "uuid" NOT NULL,
    "pod_description_id" bigint NOT NULL,
    "revision" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "toit_artemis"."pods" OWNER TO "postgres";


ALTER TABLE ONLY "public"."artemis_services" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."artemis_services_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."events" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."events_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."roles" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."roles_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sdks" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sdks_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."service_images" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."service_images_id_seq"'::"regclass");



ALTER TABLE ONLY "toit_artemis"."events" ALTER COLUMN "id" SET DEFAULT "nextval"('"toit_artemis"."events_id_seq"'::"regclass");



ALTER TABLE ONLY "toit_artemis"."pod_descriptions" ALTER COLUMN "id" SET DEFAULT "nextval"('"toit_artemis"."pod_descriptions_id_seq"'::"regclass");



ALTER TABLE ONLY "toit_artemis"."pod_tags" ALTER COLUMN "id" SET DEFAULT "nextval"('"toit_artemis"."pod_tags_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."artemis_services"
    ADD CONSTRAINT "artemis_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."artemis_services"
    ADD CONSTRAINT "artemis_services_version_key" UNIQUE ("version");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_alias_key" UNIQUE ("alias");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_user_uid_organization_uid_key" UNIQUE ("user_id", "organization_id");



ALTER TABLE ONLY "public"."sdks"
    ADD CONSTRAINT "sdks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sdks"
    ADD CONSTRAINT "sdks_version_key" UNIQUE ("version");



ALTER TABLE ONLY "public"."service_images"
    ADD CONSTRAINT "service_images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."service_images"
    ADD CONSTRAINT "service_images_sdk_id_service_id_key" UNIQUE ("sdk_id", "service_id");



ALTER TABLE ONLY "toit_artemis"."devices"
    ADD CONSTRAINT "devices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "toit_artemis"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "toit_artemis"."goals"
    ADD CONSTRAINT "goals_pkey" PRIMARY KEY ("device_id");



ALTER TABLE ONLY "toit_artemis"."pod_descriptions"
    ADD CONSTRAINT "pod_descriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "toit_artemis"."pod_tags"
    ADD CONSTRAINT "pod_tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "toit_artemis"."pods"
    ADD CONSTRAINT "pods_pkey" PRIMARY KEY ("id", "fleet_id");



CREATE INDEX "events_device_id_created_at_idx" ON "public"."events" USING "btree" ("device_id", "created_at" DESC);



CREATE INDEX "events_device_id" ON "toit_artemis"."events" USING "btree" ("device_id");



CREATE INDEX "events_device_id_timestamp_idx" ON "toit_artemis"."events" USING "btree" ("device_id", "timestamp" DESC);



CREATE INDEX "events_device_id_type_timestamp_idx" ON "toit_artemis"."events" USING "btree" ("device_id", "type", "timestamp" DESC);



CREATE INDEX "pod_descriptions_name_idx" ON "toit_artemis"."pod_descriptions" USING "btree" ("name");



CREATE UNIQUE INDEX "pod_tags_pod_description_id_tag_idx" ON "toit_artemis"."pod_tags" USING "btree" ("pod_description_id", "tag");



CREATE INDEX "pod_tags_pod_id_idx" ON "toit_artemis"."pod_tags" USING "btree" ("pod_id");



CREATE INDEX "pod_tags_tag_idx" ON "toit_artemis"."pod_tags" USING "btree" ("tag");



CREATE INDEX "pods_created_at_idx" ON "toit_artemis"."pods" USING "btree" ("created_at" DESC);



CREATE UNIQUE INDEX "pods_fleet_id_name_idx" ON "toit_artemis"."pod_descriptions" USING "btree" ("fleet_id", "name");



CREATE INDEX "pods_id_idx" ON "toit_artemis"."pods" USING "btree" ("id");



CREATE INDEX "pods_pod_description_id_created_at_idx" ON "toit_artemis"."pods" USING "btree" ("pod_description_id", "created_at" DESC);



CREATE INDEX "pods_pod_description_id_idx" ON "toit_artemis"."pods" USING "btree" ("pod_description_id");



CREATE UNIQUE INDEX "pods_pod_description_id_revision_idx" ON "toit_artemis"."pods" USING "btree" ("pod_description_id", "revision");



CREATE OR REPLACE TRIGGER "create_admin_after_new_organization" AFTER INSERT ON "public"."organizations" FOR EACH ROW EXECUTE FUNCTION "public"."create_admin_for_new_organization"();



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "devices_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_owner_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."service_images"
    ADD CONSTRAINT "service_images_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."service_images"
    ADD CONSTRAINT "service_images_sdk_id_fkey" FOREIGN KEY ("sdk_id") REFERENCES "public"."sdks"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."service_images"
    ADD CONSTRAINT "service_images_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "public"."artemis_services"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "toit_artemis"."events"
    ADD CONSTRAINT "events_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "toit_artemis"."devices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "toit_artemis"."devices"
    ADD CONSTRAINT "fk_id" FOREIGN KEY ("id") REFERENCES "public"."devices"("alias") ON DELETE CASCADE;



ALTER TABLE ONLY "toit_artemis"."goals"
    ADD CONSTRAINT "goals_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "toit_artemis"."devices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "toit_artemis"."pod_tags"
    ADD CONSTRAINT "pod_tags_pod_description_id_fkey" FOREIGN KEY ("pod_description_id") REFERENCES "toit_artemis"."pod_descriptions"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "toit_artemis"."pod_tags"
    ADD CONSTRAINT "pod_tags_pod_id_fleet_id_fkey" FOREIGN KEY ("pod_id", "fleet_id") REFERENCES "toit_artemis"."pods"("id", "fleet_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "toit_artemis"."pods"
    ADD CONSTRAINT "pods_pod_description_id_fkey" FOREIGN KEY ("pod_description_id") REFERENCES "toit_artemis"."pod_descriptions"("id") ON UPDATE CASCADE ON DELETE CASCADE;



CREATE POLICY "Admins can do everything to organization" ON "public"."organizations" TO "authenticated" USING ("public"."is_auth_admin_of_org"("id"));



CREATE POLICY "Admins can modify roles" ON "public"."roles" TO "authenticated" USING ("public"."is_auth_admin_of_org"("organization_id")) WITH CHECK ("public"."is_auth_admin_of_org"("organization_id"));



CREATE POLICY "Admins can modify the SDK table" ON "public"."sdks" TO "authenticated" USING ("public"."is_artemis_admin"()) WITH CHECK ("public"."is_artemis_admin"());



CREATE POLICY "Admins can modify the service table" ON "public"."artemis_services" TO "authenticated" USING ("public"."is_artemis_admin"()) WITH CHECK ("public"."is_artemis_admin"());



CREATE POLICY "Admins can modify the service-images table" ON "public"."service_images" TO "authenticated" USING ("public"."is_artemis_admin"()) WITH CHECK ("public"."is_artemis_admin"());



CREATE POLICY "Anon and auth users can see the SDK table" ON "public"."sdks" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anon and auth users can see the service table" ON "public"."artemis_services" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Anon and auth users can see the service-images table" ON "public"."service_images" FOR SELECT TO "authenticated", "anon" USING ((("organization_id" IS NULL) OR "public"."is_auth_member_of_org"("organization_id")));



CREATE POLICY "Enable insert of events to authenticated" ON "public"."events" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert of events to everyone" ON "public"."events" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "Members can read organization" ON "public"."organizations" FOR SELECT TO "authenticated" USING ("public"."is_auth_member_of_org"("id"));



CREATE POLICY "Organization members can read events" ON "public"."events" FOR SELECT TO "authenticated" USING ("public"."is_auth_member_of_org"(( SELECT "devices"."organization_id"
   FROM "public"."devices"
  WHERE ("devices"."id" = "events"."device_id"))));



CREATE POLICY "Organization members can read profiles" ON "public"."profiles" FOR SELECT TO "authenticated" USING ("public"."is_auth_in_same_org_as"("id"));



CREATE POLICY "Owner can do everything to organization" ON "public"."organizations" TO "authenticated" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));



CREATE POLICY "Profile can only be changed by owner" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Profile can only be seen by owners" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "User must be in org of device" ON "public"."devices" TO "authenticated" USING ("public"."is_auth_member_of_org"("organization_id")) WITH CHECK ("public"."is_auth_member_of_org"("organization_id"));



CREATE POLICY "Users can remove themselves from an organization" ON "public"."roles" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can see members of the orgs they are a member of" ON "public"."roles" FOR SELECT TO "authenticated" USING ("public"."is_auth_member_of_org"("organization_id"));



ALTER TABLE "public"."admins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."artemis_services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."devices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."organizations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sdks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."service_images" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "Authenticated have full access to devices of the orgs they are " ON "toit_artemis"."devices" TO "authenticated" USING ("public"."is_auth_in_org_of_alias"("id")) WITH CHECK ("public"."is_auth_in_org_of_alias"("id"));



CREATE POLICY "Authenticated have full access to events table of devices in th" ON "toit_artemis"."events" TO "authenticated" USING ("public"."is_auth_in_org_of_alias"("device_id")) WITH CHECK ("public"."is_auth_in_org_of_alias"("device_id"));



CREATE POLICY "Authenticated have full access to goals table of devices of the" ON "toit_artemis"."goals" TO "authenticated" USING ("public"."is_auth_in_org_of_alias"("device_id")) WITH CHECK ("public"."is_auth_in_org_of_alias"("device_id"));



CREATE POLICY "Authenticated have full access to pod_descriptions in the org t" ON "toit_artemis"."pod_descriptions" TO "authenticated" USING ("public"."is_auth_member_of_org"("organization_id")) WITH CHECK ("public"."is_auth_member_of_org"("organization_id"));



CREATE POLICY "Authenticated have full access to pod_tags table for descriptio" ON "toit_artemis"."pod_tags" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "toit_artemis"."pod_descriptions" "pd"
  WHERE ("pd"."id" = "pod_tags"."pod_description_id")))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "toit_artemis"."pod_descriptions" "pd"
  WHERE ("pd"."id" = "pod_tags"."pod_description_id"))));



CREATE POLICY "Authenticated have full access to pods table for descriptions t" ON "toit_artemis"."pods" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "toit_artemis"."pod_descriptions" "pd"
  WHERE ("pd"."id" = "pods"."pod_description_id")))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "toit_artemis"."pod_descriptions" "pd"
  WHERE ("pd"."id" = "pods"."pod_description_id"))));



ALTER TABLE "toit_artemis"."devices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "toit_artemis"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "toit_artemis"."goals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "toit_artemis"."pod_descriptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "toit_artemis"."pod_tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "toit_artemis"."pods" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";








GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT USAGE ON SCHEMA "toit_artemis" TO "anon";
GRANT USAGE ON SCHEMA "toit_artemis" TO "authenticated";
GRANT USAGE ON SCHEMA "toit_artemis" TO "service_role";






































































































































































































GRANT ALL ON FUNCTION "public"."create_admin_for_new_organization"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_admin_for_new_organization"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_admin_for_new_organization"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_profile_for_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_profile_for_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_profile_for_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."email_for_id"("_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."email_for_id"("_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."email_for_id"("_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_artemis_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_artemis_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_artemis_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_auth_admin_of_org"("_organization_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_auth_admin_of_org"("_organization_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_auth_admin_of_org"("_organization_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_auth_in_org_of_alias"("_device_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_auth_in_org_of_alias"("_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_auth_in_org_of_alias"("_device_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_auth_in_same_org_as"("_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_auth_in_same_org_as"("_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_auth_in_same_org_as"("_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_auth_member_of_org"("_organization_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_auth_member_of_org"("_organization_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_auth_member_of_org"("_organization_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."toit_artemis.get_devices"("_device_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_devices"("_device_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_devices"("_device_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."toit_artemis.get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."delete_old_events"() TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."delete_old_events"() TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."delete_old_events"() TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_devices"("_device_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_devices"("_device_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_devices"("_device_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_goal"("_device_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_goal"("_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_goal"("_device_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_goal_no_event"("_device_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_goal_no_event"("_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_goal_no_event"("_device_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_pod_descriptions"("_fleet_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_pod_descriptions"("_fleet_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_pod_descriptions"("_fleet_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_pod_descriptions_by_ids"("_description_ids" bigint[]) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_pod_descriptions_by_ids"("_description_ids" bigint[]) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_pod_descriptions_by_ids"("_description_ids" bigint[]) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."get_state"("_device_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."get_state"("_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."get_state"("_device_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."max_event_age"() TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."max_event_age"() TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."max_event_age"() TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."new_provisioned"("_device_id" "uuid", "_state" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."new_provisioned"("_device_id" "uuid", "_state" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."new_provisioned"("_device_id" "uuid", "_state" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."remove_device"("_device_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."remove_device"("_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."remove_device"("_device_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."set_goal"("_device_id" "uuid", "_goal" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."set_goal"("_device_id" "uuid", "_goal" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."set_goal"("_device_id" "uuid", "_goal" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."set_goals"("_device_ids" "uuid"[], "_goals" "jsonb"[]) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."set_goals"("_device_ids" "uuid"[], "_goals" "jsonb"[]) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."set_goals"("_device_ids" "uuid"[], "_goals" "jsonb"[]) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."update_state"("_device_id" "uuid", "_state" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."update_state"("_device_id" "uuid", "_state" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."update_state"("_device_id" "uuid", "_state" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "toit_artemis"."upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") TO "service_role";
























GRANT ALL ON TABLE "public"."devices" TO "anon";
GRANT ALL ON TABLE "public"."devices" TO "authenticated";
GRANT ALL ON TABLE "public"."devices" TO "service_role";



GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON TABLE "public"."organizations" TO "anon";
GRANT ALL ON TABLE "public"."organizations" TO "authenticated";
GRANT ALL ON TABLE "public"."organizations" TO "service_role";



GRANT ALL ON TABLE "public"."active_devices" TO "anon";
GRANT ALL ON TABLE "public"."active_devices" TO "authenticated";
GRANT ALL ON TABLE "public"."active_devices" TO "service_role";



GRANT ALL ON TABLE "public"."admins" TO "anon";
GRANT ALL ON TABLE "public"."admins" TO "authenticated";
GRANT ALL ON TABLE "public"."admins" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."admin_with_profile" TO "service_role";



GRANT ALL ON TABLE "public"."artemis_services" TO "anon";
GRANT ALL ON TABLE "public"."artemis_services" TO "authenticated";
GRANT ALL ON TABLE "public"."artemis_services" TO "service_role";



GRANT ALL ON SEQUENCE "public"."artemis_services_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."artemis_services_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."artemis_services_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."events_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."profiles_with_email" TO "anon";
GRANT ALL ON TABLE "public"."profiles_with_email" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles_with_email" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON TABLE "public"."roles_with_profile" TO "anon";
GRANT ALL ON TABLE "public"."roles_with_profile" TO "authenticated";
GRANT ALL ON TABLE "public"."roles_with_profile" TO "service_role";



GRANT ALL ON TABLE "public"."organization_admins" TO "service_role";



GRANT ALL ON SEQUENCE "public"."roles_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."roles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."roles_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sdks" TO "anon";
GRANT ALL ON TABLE "public"."sdks" TO "authenticated";
GRANT ALL ON TABLE "public"."sdks" TO "service_role";



GRANT ALL ON TABLE "public"."service_images" TO "anon";
GRANT ALL ON TABLE "public"."service_images" TO "authenticated";
GRANT ALL ON TABLE "public"."service_images" TO "service_role";



GRANT ALL ON TABLE "public"."sdk_service_versions" TO "anon";
GRANT ALL ON TABLE "public"."sdk_service_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."sdk_service_versions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sdks_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sdks_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sdks_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."service_images_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."service_images_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."service_images_id_seq" TO "service_role";



GRANT ALL ON TABLE "toit_artemis"."devices" TO "anon";
GRANT ALL ON TABLE "toit_artemis"."devices" TO "authenticated";
GRANT ALL ON TABLE "toit_artemis"."devices" TO "service_role";



GRANT ALL ON TABLE "toit_artemis"."events" TO "anon";
GRANT ALL ON TABLE "toit_artemis"."events" TO "authenticated";
GRANT ALL ON TABLE "toit_artemis"."events" TO "service_role";



GRANT ALL ON SEQUENCE "toit_artemis"."events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "toit_artemis"."events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "toit_artemis"."events_id_seq" TO "service_role";



GRANT ALL ON TABLE "toit_artemis"."goals" TO "anon";
GRANT ALL ON TABLE "toit_artemis"."goals" TO "authenticated";
GRANT ALL ON TABLE "toit_artemis"."goals" TO "service_role";



GRANT ALL ON TABLE "toit_artemis"."pod_descriptions" TO "anon";
GRANT ALL ON TABLE "toit_artemis"."pod_descriptions" TO "authenticated";
GRANT ALL ON TABLE "toit_artemis"."pod_descriptions" TO "service_role";



GRANT ALL ON SEQUENCE "toit_artemis"."pod_descriptions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "toit_artemis"."pod_descriptions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "toit_artemis"."pod_descriptions_id_seq" TO "service_role";



GRANT ALL ON TABLE "toit_artemis"."pod_tags" TO "anon";
GRANT ALL ON TABLE "toit_artemis"."pod_tags" TO "authenticated";
GRANT ALL ON TABLE "toit_artemis"."pod_tags" TO "service_role";



GRANT ALL ON SEQUENCE "toit_artemis"."pod_tags_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "toit_artemis"."pod_tags_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "toit_artemis"."pod_tags_id_seq" TO "service_role";



GRANT ALL ON TABLE "toit_artemis"."pods" TO "anon";
GRANT ALL ON TABLE "toit_artemis"."pods" TO "authenticated";
GRANT ALL ON TABLE "toit_artemis"."pods" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON SEQUENCES  TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON FUNCTIONS  TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "toit_artemis" GRANT ALL ON TABLES  TO "service_role";




























--
-- Dumped schema changes for auth and storage
--

CREATE OR REPLACE TRIGGER "create_profile_after_new_user" AFTER INSERT ON "auth"."users" FOR EACH ROW EXECUTE FUNCTION "public"."create_profile_for_new_user"();



CREATE POLICY "Admins can change service images" ON "storage"."objects" TO "authenticated" USING ((("bucket_id" = 'service-images'::"text") AND "public"."is_artemis_admin"())) WITH CHECK ((("bucket_id" = 'service-images'::"text") AND "public"."is_artemis_admin"()));



CREATE POLICY "Admins have access to CLI snapshots" ON "storage"."objects" TO "authenticated" USING ((("bucket_id" = 'cli-snapshots'::"text") AND "public"."is_artemis_admin"())) WITH CHECK ((("bucket_id" = 'cli-snapshots'::"text") AND "public"."is_artemis_admin"()));



CREATE POLICY "Admins have access to service snapshots" ON "storage"."objects" TO "authenticated" USING ((("bucket_id" = 'service-snapshots'::"text") AND "public"."is_artemis_admin"())) WITH CHECK ((("bucket_id" = 'service-snapshots'::"text") AND "public"."is_artemis_admin"()));



CREATE POLICY "All users can read service images" ON "storage"."objects" FOR SELECT TO "authenticated", "anon" USING (("bucket_id" = 'service-images'::"text"));



CREATE POLICY "Authenticated have full access to pod storage in their orgs" ON "storage"."objects" TO "authenticated" USING ((("bucket_id" = 'toit-artemis-pods'::"text") AND "public"."is_auth_member_of_org"((("storage"."foldername"("name"))[1])::"uuid"))) WITH CHECK ((("bucket_id" = 'toit-artemis-pods'::"text") AND "public"."is_auth_member_of_org"((("storage"."foldername"("name"))[1])::"uuid")));



CREATE POLICY "Authenticated have full access to storage in their orgs" ON "storage"."objects" TO "authenticated" USING ((("bucket_id" = 'toit-artemis-assets'::"text") AND "public"."is_auth_member_of_org"((("storage"."foldername"("name"))[1])::"uuid"))) WITH CHECK ((("bucket_id" = 'toit-artemis-assets'::"text") AND "public"."is_auth_member_of_org"((("storage"."foldername"("name"))[1])::"uuid")));



