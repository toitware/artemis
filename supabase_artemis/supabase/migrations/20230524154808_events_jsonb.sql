-- Copyright (C) 2023 Toitware ApS. All rights reserved.

ALTER TABLE public.events
    ALTER COLUMN data
    SET DATA TYPE JSONB;
