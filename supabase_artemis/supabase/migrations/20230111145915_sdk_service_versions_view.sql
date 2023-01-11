-- Copyright (C) 2023 Toitware ApS. All rights reserved.

-- Provide a view that combines the sdk and service versions.
CREATE VIEW public.sdk_service_versions
WITH (security_invoker=on)
AS
  SELECT sdks.version as sdk_version, artemis_services.version as service_version, i.image
  FROM sdks, artemis_services,  service_images i
  WHERE sdks.id = i.sdk_id AND artemis_services.id = i.service_id;
