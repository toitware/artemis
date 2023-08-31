-- Copyright (C) 2023 Toitware ApS.
-- Use of this source code is governed by an MIT-style license that can be
-- found in the LICENSE file.

CREATE INDEX IF NOT EXISTS events_device_id_timestamp_idx
    ON toit_artemis.events (device_id, timestamp DESC);
