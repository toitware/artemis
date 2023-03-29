-- Copyright (C) 2023 Toitware ApS. All rights reserved.

ALTER TABLE public.service_images
    ADD COLUMN "organization_id" UUID;

ALTER TABLE public.service_images
    ADD CONSTRAINT "service_images_organization_id_fkey"
    FOREIGN KEY (organization_id)
    REFERENCES organizations(id);

ALTER POLICY "Anon and auth users can see the service-images table"
    ON public.service_images
    USING (organization_id IS NULL OR is_auth_member_of_org(organization_id));

-- No need to have a unique image
ALTER TABLE public.service_images
    DROP CONSTRAINT service_images_image_key;

-- Provide a view that combines the sdk and service versions.
DROP VIEW public.sdk_service_versions;
CREATE VIEW public.sdk_service_versions
WITH (security_invoker=on)
AS
    SELECT sdks.version as sdk_version, artemis_services.version as service_version, i.organization_id as organization_id, i.image
    FROM sdks, artemis_services, service_images i
    WHERE sdks.id = i.sdk_id
        AND artemis_services.id = i.service_id;
