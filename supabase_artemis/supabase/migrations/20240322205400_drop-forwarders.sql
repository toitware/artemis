-- Copyright (C) 2024 Toitware ApS. All rights reserved.

DROP FUNCTION IF EXISTS public."toit_artemis.delete_pod_descriptions"(_fleet_id UUID, _description_ids BIGINT[]);
DROP FUNCTION IF EXISTS public."toit_artemis.delete_pod_tag"(_pod_description_id BIGINT, _tag TEXT);
DROP FUNCTION IF EXISTS public."toit_artemis.delete_pods"(_fleet_id UUID, _pod_ids UUID[]);
DROP FUNCTION IF EXISTS public."toit_artemis.get_devices"(_device_ids UUID[]);
DROP FUNCTION IF EXISTS public."toit_artemis.get_events"(_device_ids UUID[], _types TEXT[], _limit INTEGER, _since TIMESTAMPTZ);
DROP FUNCTION IF EXISTS public."toit_artemis.get_goal"(_device_id UUID);
DROP FUNCTION IF EXISTS public."toit_artemis.get_goal_no_event"(_device_id UUID);
DROP FUNCTION IF EXISTS public."toit_artemis.get_pod_descriptions"(_fleet_id UUID);
DROP FUNCTION IF EXISTS public."toit_artemis.get_pod_descriptions_by_ids"(_description_ids BIGINT[]);
DROP FUNCTION IF EXISTS public."toit_artemis.get_pod_descriptions_by_names"(_fleet_id UUID, _organization_id UUID, _names TEXT[], _create_if_absent BOOLEAN);
DROP FUNCTION IF EXISTS public."toit_artemis.get_pods"(_pod_description_id BIGINT, _limit BIGINT, _offset BIGINT);
DROP FUNCTION IF EXISTS public."toit_artemis.get_pods_by_ids"(_fleet_id UUID, _pod_ids UUID[]);
DROP FUNCTION IF EXISTS public."toit_artemis.get_pods_by_reference"(_fleet_id UUID, _references JSONB);
DROP FUNCTION IF EXISTS public."toit_artemis.get_state"(_device_id UUID);
DROP FUNCTION IF EXISTS public."toit_artemis.insert_pod"(_pod_id UUID, _pod_description_id BIGINT);
DROP FUNCTION IF EXISTS public."toit_artemis.new_provisioned"(_device_id UUID, _state JSONB);
DROP FUNCTION IF EXISTS public."toit_artemis.remove_device"(_device_id UUID);
DROP FUNCTION IF EXISTS public."toit_artemis.report_event"(_device_id UUID, _type TEXT, _data JSONB);
DROP FUNCTION IF EXISTS public."toit_artemis.set_goal"(_device_id UUID, _goal JSONB);
DROP FUNCTION IF EXISTS public."toit_artemis.set_pod_tag"(_pod_id UUID, _pod_description_id BIGINT, _tag TEXT, _force BOOLEAN);
DROP FUNCTION IF EXISTS public."toit_artemis.update_state"(_device_id UUID, _state JSONB);
DROP FUNCTION IF EXISTS public."toit_artemis.upsert_pod_description"(_fleet_id UUID, _organization_id UUID, _name TEXT, _description TEXT);
