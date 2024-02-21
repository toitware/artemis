-- Copyright (C) 2024 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

CREATE OR REPLACE FUNCTION toit_artemis.set_pod_tag(
        _pod_id UUID,
        _pod_description_id BIGINT,
        _tag TEXT,
        _force BOOLEAN
    )
RETURNS VOID
SECURITY INVOKER
LANGUAGE plpgsql
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
