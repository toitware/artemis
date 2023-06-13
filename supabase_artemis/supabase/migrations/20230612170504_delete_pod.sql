-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

CREATE OR REPLACE FUNCTION toit_artemis.delete_pod_descriptions(
        _fleet_id UUID,
        _description_ids BIGINT[]
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    _pod_description_id BIGINT;
BEGIN
    FOR _pod_description_id IN SELECT unnest(_description_ids) LOOP
        DELETE FROM toit_artemis.pod_descriptions WHERE id = _pod_description_id AND fleet_id = _fleet_id;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION toit_artemis.delete_pods(
        _fleet_id UUID,
        _pod_ids UUID[]
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
DECLARE
    _pod_id UUID;
BEGIN
    FOR _pod_id IN SELECT unnest(_pod_ids) LOOP
        DELETE FROM toit_artemis.pods WHERE id = _pod_id AND fleet_id = _fleet_id;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.delete_pod_descriptions"(
        _fleet_id UUID,
        _description_ids BIGINT[]
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM * FROM toit_artemis.delete_pod_descriptions(_fleet_id, _description_ids);
END;
$$;

CREATE OR REPLACE FUNCTION public."toit_artemis.delete_pods"(
        _fleet_id UUID,
        _pod_ids UUID[]
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM * FROM toit_artemis.delete_pods(_fleet_id, _pod_ids);
END;
$$;
