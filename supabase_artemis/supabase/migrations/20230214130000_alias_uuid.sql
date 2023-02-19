-- Copyright (C) 2023 Toitware ApS. All rights reserved.

ALTER TABLE public.devices ALTER COLUMN "alias" DROP DEFAULT;
ALTER TABLE public.devices ALTER COLUMN "alias" DROP NOT NULL;
ALTER TABLE public.devices ALTER COLUMN "alias" SET DATA TYPE uuid USING "alias"::uuid;
ALTER TABLE public.devices ALTER COLUMN "alias" SET DEFAULT uuid_generate_v4();

CREATE UNIQUE INDEX devices_alias_key ON public.devices USING btree (alias);
ALTER TABLE public.devices ADD CONSTRAINT "devices_alias_key" UNIQUE using index "devices_alias_key";
