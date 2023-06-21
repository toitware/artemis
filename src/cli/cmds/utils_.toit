// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.os
import uuid
import ..artemis
import ..config
import ..cache
import ..fleet
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

with_fleet parsed/cli.Parsed config/Config cache/Cache ui/Ui [block]:
  fleet_root := compute_fleet_root parsed config ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache --config=config
    block.call fleet

compute_fleet_root parsed/cli.Parsed config/Config ui/Ui -> string:
  fleet_root := parsed["fleet-root"]
  if fleet_root: return fleet_root
  fleet_root_env := os.env.get "ARTEMIS_FLEET_ROOT"
  if fleet_root_env:
    ui.do --kind=Ui.DEBUG: | printer/Printer |
      printer.emit "Using fleet-root '$fleet_root_env' provided by environment variable."
    return fleet_root_env
  return "."
