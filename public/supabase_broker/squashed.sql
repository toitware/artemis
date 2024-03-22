
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

CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgsodium" WITH SCHEMA "pgsodium";

CREATE SCHEMA IF NOT EXISTS "supabase_migrations";

ALTER SCHEMA "supabase_migrations" OWNER TO "postgres";

CREATE SCHEMA IF NOT EXISTS "toit_artemis";

ALTER SCHEMA "toit_artemis" OWNER TO "postgres";

CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

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

CREATE OR REPLACE FUNCTION "public"."toit_artemis.delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM * FROM toit_artemis.delete_pod_descriptions(_fleet_id, _description_ids);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM toit_artemis.delete_pod_tag(_pod_description_id, _tag);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM * FROM toit_artemis.delete_pods(_fleet_id, _pod_ids);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) OWNER TO "postgres";

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

CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_goal"("_device_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN (SELECT toit_artemis.get_goal(_device_id));
END;
$$;

ALTER FUNCTION "public"."toit_artemis.get_goal"("_device_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_goal_no_event"("_device_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN (SELECT toit_artemis.get_goal_no_event(_device_id));
END;
$$;

ALTER FUNCTION "public"."toit_artemis.get_goal_no_event"("_device_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_pod_descriptions"("_fleet_id" "uuid") RETURNS SETOF "toit_artemis"."poddescription"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions(_fleet_id);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.get_pod_descriptions"("_fleet_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_pod_descriptions_by_ids"("_description_ids" bigint[]) RETURNS SETOF "toit_artemis"."poddescription"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_ids(_description_ids);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.get_pod_descriptions_by_ids"("_description_ids" bigint[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) RETURNS SETOF "toit_artemis"."poddescription"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pod_descriptions_by_names(_fleet_id, _organization_id, _names, _create_if_absent);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) RETURNS SETOF "toit_artemis"."pod"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods(_pod_description_id, _limit, _offset);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) RETURNS SETOF "toit_artemis"."pod"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods_by_ids(_fleet_id, _pod_ids);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") RETURNS TABLE("pod_id" "uuid", "name" "text", "revision" integer, "tag" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM toit_artemis.get_pods_by_reference(_fleet_id, _references);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.get_state"("_device_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN (SELECT toit_artemis.get_state(_device_id));
END;
$$;

ALTER FUNCTION "public"."toit_artemis.get_state"("_device_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM toit_artemis.insert_pod(_pod_id, _pod_description_id);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.new_provisioned"("_device_id" "uuid", "_state" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM toit_artemis.new_provisioned(_device_id, _state);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.new_provisioned"("_device_id" "uuid", "_state" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.remove_device"("_device_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM toit_artemis.remove_device(_device_id);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.remove_device"("_device_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM toit_artemis.report_event(_device_id, _type, _data);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.set_goal"("_device_id" "uuid", "_goal" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM toit_artemis.set_goal(_device_id, _goal);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.set_goal"("_device_id" "uuid", "_goal" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM toit_artemis.set_pod_tag(_pod_id, _pod_description_id, _tag, _force);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.update_state"("_device_id" "uuid", "_state" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM toit_artemis.update_state(_device_id, _state);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.update_state"("_device_id" "uuid", "_state" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."toit_artemis.upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN toit_artemis.upsert_pod_description(_fleet_id, _organization_id, _name, _description);
END;
$$;

ALTER FUNCTION "public"."toit_artemis.upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") OWNER TO "postgres";

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
    AS $$
DECLARE filtered_device_ids UUID[];
BEGIN
    -- We are using the RLS to filter out device ids the invoker doesn't have
    -- access to. This is a performance optimization.
    SELECT array_agg(DISTINCT d.id)
    INTO filtered_device_ids
    FROM unnest(_device_ids) as input(id)
    JOIN toit_artemis.devices d ON input.id = d.id;

    RETURN QUERY
        SELECT p.device_id, g.goal, d.state
        FROM unnest(filtered_device_ids) AS p(device_id)
        LEFT JOIN toit_artemis.goals g USING (device_id)
        LEFT JOIN toit_artemis.devices d ON p.device_id = d.id;
END;
$$;

ALTER FUNCTION "toit_artemis"."get_devices"("_device_ids" "uuid"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "toit_artemis"."get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) RETURNS TABLE("device_id" "uuid", "type" "text", "ts" timestamp with time zone, "data" "jsonb")
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _type TEXT;
    filtered_device_ids UUID[];
BEGIN
    -- We are using the RLS to filter out device ids the invoker doesn't have
    -- access to. This is a performance optimization.
    SELECT array_agg(DISTINCT d.id)
    INTO filtered_device_ids
    FROM unnest(_device_ids) as input(id)
    JOIN toit_artemis.devices d ON input.id = d.id;

    IF ARRAY_LENGTH(_types, 1) = 1 THEN
        _type := _types[1];
        RETURN QUERY
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest(filtered_device_ids) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.type = _type
                        AND e.timestamp >= _since
                ORDER BY e.timestamp DESC
                LIMIT _limit
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC;
    ELSEIF ARRAY_LENGTH(_types, 1) > 1 THEN
        RETURN QUERY
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest(filtered_device_ids) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.type = ANY(_types)
                        AND e.timestamp >= _since
                ORDER BY e.timestamp DESC
                LIMIT _limit
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC;
    ELSE
        -- Note that 'ARRAY_LENGTH' of an empty array does not return 0 but null.
        RETURN QUERY
            SELECT e.device_id, e.type, e.timestamp, e.data
            FROM unnest(filtered_device_ids) AS p(device_id)
            CROSS JOIN LATERAL (
                SELECT e.*
                FROM toit_artemis.events e
                WHERE e.device_id = p.device_id
                        AND e.timestamp >= _since
                ORDER BY e.timestamp DESC
                LIMIT _limit
            ) AS e
            ORDER BY e.device_id, e.timestamp DESC;
    END IF;
END;
$$;

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

CREATE TABLE IF NOT EXISTS "supabase_migrations"."schema_migrations" (
    "version" "text" NOT NULL,
    "statements" "text"[],
    "name" "text"
);

ALTER TABLE "supabase_migrations"."schema_migrations" OWNER TO "postgres";

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

ALTER TABLE ONLY "toit_artemis"."events" ALTER COLUMN "id" SET DEFAULT "nextval"('"toit_artemis"."events_id_seq"'::"regclass");

ALTER TABLE ONLY "toit_artemis"."pod_descriptions" ALTER COLUMN "id" SET DEFAULT "nextval"('"toit_artemis"."pod_descriptions_id_seq"'::"regclass");

ALTER TABLE ONLY "toit_artemis"."pod_tags" ALTER COLUMN "id" SET DEFAULT "nextval"('"toit_artemis"."pod_tags_id_seq"'::"regclass");

ALTER TABLE ONLY "supabase_migrations"."schema_migrations"
    ADD CONSTRAINT "schema_migrations_pkey" PRIMARY KEY ("version");

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

ALTER TABLE ONLY "toit_artemis"."events"
    ADD CONSTRAINT "events_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "toit_artemis"."devices"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "toit_artemis"."goals"
    ADD CONSTRAINT "goals_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "toit_artemis"."devices"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "toit_artemis"."pod_tags"
    ADD CONSTRAINT "pod_tags_pod_description_id_fkey" FOREIGN KEY ("pod_description_id") REFERENCES "toit_artemis"."pod_descriptions"("id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "toit_artemis"."pod_tags"
    ADD CONSTRAINT "pod_tags_pod_id_fleet_id_fkey" FOREIGN KEY ("pod_id", "fleet_id") REFERENCES "toit_artemis"."pods"("id", "fleet_id") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "toit_artemis"."pods"
    ADD CONSTRAINT "pods_pod_description_id_fkey" FOREIGN KEY ("pod_description_id") REFERENCES "toit_artemis"."pod_descriptions"("id") ON UPDATE CASCADE ON DELETE CASCADE;

CREATE POLICY "Authenticated have full access to devices table" ON "toit_artemis"."devices" TO "authenticated" USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated have full access to events table" ON "toit_artemis"."events" TO "authenticated" USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated have full access to goals table" ON "toit_artemis"."goals" TO "authenticated" USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated have full access to pod_descriptions table" ON "toit_artemis"."pod_descriptions" TO "authenticated" USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated have full access to pod_tags table" ON "toit_artemis"."pod_tags" TO "authenticated" USING (true) WITH CHECK (true);

CREATE POLICY "Authenticated have full access to pods table" ON "toit_artemis"."pods" TO "authenticated" USING (true) WITH CHECK (true);

ALTER TABLE "toit_artemis"."devices" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "toit_artemis"."events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "toit_artemis"."goals" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "toit_artemis"."pod_descriptions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "toit_artemis"."pod_tags" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "toit_artemis"."pods" ENABLE ROW LEVEL SECURITY;

GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

GRANT USAGE ON SCHEMA "toit_artemis" TO "anon";
GRANT USAGE ON SCHEMA "toit_artemis" TO "authenticated";
GRANT USAGE ON SCHEMA "toit_artemis" TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.delete_pod_descriptions"("_fleet_id" "uuid", "_description_ids" bigint[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.delete_pod_tag"("_pod_description_id" bigint, "_tag" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.delete_pods"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_devices"("_device_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_devices"("_device_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_devices"("_device_ids" "uuid"[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_events"("_device_ids" "uuid"[], "_types" "text"[], "_limit" integer, "_since" timestamp with time zone) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_goal"("_device_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_goal"("_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_goal"("_device_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_goal_no_event"("_device_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_goal_no_event"("_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_goal_no_event"("_device_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_pod_descriptions"("_fleet_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pod_descriptions"("_fleet_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pod_descriptions"("_fleet_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_pod_descriptions_by_ids"("_description_ids" bigint[]) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pod_descriptions_by_ids"("_description_ids" bigint[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pod_descriptions_by_ids"("_description_ids" bigint[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pod_descriptions_by_names"("_fleet_id" "uuid", "_organization_id" "uuid", "_names" "text"[], "_create_if_absent" boolean) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pods"("_pod_description_id" bigint, "_limit" bigint, "_offset" bigint) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pods_by_ids"("_fleet_id" "uuid", "_pod_ids" "uuid"[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_pods_by_reference"("_fleet_id" "uuid", "_references" "jsonb") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.get_state"("_device_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_state"("_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.get_state"("_device_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.insert_pod"("_pod_id" "uuid", "_pod_description_id" bigint) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.new_provisioned"("_device_id" "uuid", "_state" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.new_provisioned"("_device_id" "uuid", "_state" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.new_provisioned"("_device_id" "uuid", "_state" "jsonb") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.remove_device"("_device_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.remove_device"("_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.remove_device"("_device_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.report_event"("_device_id" "uuid", "_type" "text", "_data" "jsonb") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.set_goal"("_device_id" "uuid", "_goal" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.set_goal"("_device_id" "uuid", "_goal" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.set_goal"("_device_id" "uuid", "_goal" "jsonb") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.update_state"("_device_id" "uuid", "_state" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.update_state"("_device_id" "uuid", "_state" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.update_state"("_device_id" "uuid", "_state" "jsonb") TO "service_role";

GRANT ALL ON FUNCTION "public"."toit_artemis.upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."toit_artemis.upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."toit_artemis.upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") TO "service_role";

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

GRANT ALL ON FUNCTION "toit_artemis"."set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."set_pod_tag"("_pod_id" "uuid", "_pod_description_id" bigint, "_tag" "text", "_force" boolean) TO "service_role";

GRANT ALL ON FUNCTION "toit_artemis"."update_state"("_device_id" "uuid", "_state" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."update_state"("_device_id" "uuid", "_state" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."update_state"("_device_id" "uuid", "_state" "jsonb") TO "service_role";

GRANT ALL ON FUNCTION "toit_artemis"."upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") TO "anon";
GRANT ALL ON FUNCTION "toit_artemis"."upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "toit_artemis"."upsert_pod_description"("_fleet_id" "uuid", "_organization_id" "uuid", "_name" "text", "_description" "text") TO "service_role";

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

RESET ALL;
