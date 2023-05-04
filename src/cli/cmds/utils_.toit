// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import uuid
import ..artemis
import ..config
import ..cache
import ..ui
import ..server_config
import ..utils

with_artemis parsed/cli.Parsed config/Config cache/Cache ui/Ui [block]:
  broker_config := get_server_from_config config CONFIG_BROKER_DEFAULT_KEY
  artemis_config := get_server_from_config config CONFIG_ARTEMIS_DEFAULT_KEY

  with_tmp_directory: | tmp_directory/string |
    artemis := Artemis
        --config=config
        --cache=cache
        --ui=ui
        --tmp_directory=tmp_directory
        --broker_config=broker_config
        --artemis_config=artemis_config
    try:
      block.call artemis
    finally:
      artemis.close

default_device_from_config config/Config -> uuid.Uuid?:
  device_id_string := config.get CONFIG_DEVICE_DEFAULT_KEY
  if not device_id_string: return null
  return uuid.parse device_id_string

default_organization_from_config config/Config -> uuid.Uuid?:
  organization_id_string := config.get CONFIG_ORGANIZATION_DEFAULT_KEY
  if not organization_id_string: return null
  return uuid.parse organization_id_string
