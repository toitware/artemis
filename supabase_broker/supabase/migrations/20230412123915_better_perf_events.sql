-- Copyright (C) 2023 Toitware ApS. All rights reserved.

CREATE INDEX IF NOT EXISTS events_device_id_timestamp_idx
    ON toit_artemis.events (device_id, timestamp DESC);
