-- Copyright (C) 2022 Toitware ApS. All rights reserved.

-- We do allow customers to reuse alias IDs.

ALTER TABLE toit_artemis.devices DROP CONSTRAINT fk_id;
ALTER TABLE public.devices DROP CONSTRAINT devices_alias_key;
