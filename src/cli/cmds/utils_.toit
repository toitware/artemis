// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.os
import uuid
import ..artemis
import ..config
import ..cache
import ..fleet
import ..ui
import ..server-config
import ..utils

with-artemis parsed/cli.Parsed config/Config cache/Cache ui/Ui [block]:
  broker-config := get-server-from-config config CONFIG-BROKER-DEFAULT-KEY
  artemis-config := get-server-from-config config CONFIG-ARTEMIS-DEFAULT-KEY

  with-tmp-directory: | tmp-directory/string |
    artemis := Artemis
        --config=config
        --cache=cache
        --ui=ui
        --tmp-directory=tmp-directory
        --broker-config=broker-config
        --artemis-config=artemis-config
    try:
      block.call artemis
    finally:
      artemis.close

default-device-from-config config/Config -> uuid.Uuid?:
  device-id-string := config.get CONFIG-DEVICE-DEFAULT-KEY
  if not device-id-string: return null
  return uuid.parse device-id-string

default-organization-from-config config/Config -> uuid.Uuid?:
  organization-id-string := config.get CONFIG-ORGANIZATION-DEFAULT-KEY
  if not organization-id-string: return null
  return uuid.parse organization-id-string

with-fleet parsed/cli.Parsed config/Config cache/Cache ui/Ui [block]:
  fleet-root := compute-fleet-root parsed config ui

  with-artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet-root artemis --ui=ui --cache=cache --config=config
    block.call fleet

compute-fleet-root parsed/cli.Parsed config/Config ui/Ui -> string:
  fleet-root := parsed["fleet-root"]
  if fleet-root: return fleet-root
  fleet-root-env := os.env.get "ARTEMIS_FLEET_ROOT"
  if fleet-root-env:
    ui.do --kind=Ui.DEBUG: | printer/Printer |
      printer.emit "Using fleet-root '$fleet-root-env' provided by environment variable."
    return fleet-root-env
  return "."
