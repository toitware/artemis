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
  artemis-config := get-server-from-config config --key=CONFIG-ARTEMIS-DEFAULT-KEY
  if not artemis-config:
    ui.abort "Default Artemis server is not configured correctly."

  with-tmp-directory: | tmp-directory/string |
    artemis := Artemis
        --config=config
        --cache=cache
        --ui=ui
        --tmp-directory=tmp-directory
        --server-config=artemis-config
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

with-devices-fleet parsed/cli.Parsed config/Config cache/Cache ui/Ui [block]:
  // If the result of the compute-call isn't a root, but a reference, then
  // the constructor call below will throw.
  fleet-root := compute-fleet-root-or-ref parsed config ui

  with-artemis parsed config cache ui: | artemis/Artemis |
    default-broker-config := get-server-from-config config --key=CONFIG-BROKER-DEFAULT-KEY
    if not default-broker-config:
      ui.abort "Default broker is not configured correctly."
    fleet := FleetWithDevices fleet-root artemis
        --default-broker-config=default-broker-config
        --ui=ui
        --cache=cache
        --config=config
    block.call fleet

with-pod-fleet parsed/cli.Parsed config/Config cache/Cache ui/Ui [block]:
  fleet-root-or-ref := compute-fleet-root-or-ref parsed config ui

  with-artemis parsed config cache ui: | artemis/Artemis |
    default-broker-config := get-server-from-config config --key=CONFIG-BROKER-DEFAULT-KEY
    if not default-broker-config:
      ui.abort "Default broker is not configured correctly."
    fleet := Fleet fleet-root-or-ref artemis
        --default-broker-config=default-broker-config
        --ui=ui
        --cache=cache
        --config=config
    block.call fleet

compute-fleet-root-or-ref parsed/cli.Parsed config/Config ui/Ui -> string:
  fleet-root := parsed["fleet-root"]  // Old deprecated argument.
  fleet-root-or-ref := parsed["fleet"]
  if fleet-root and fleet-root-or-ref:
    ui.abort "The arguments --fleet-root and --fleet are mutually exclusive."
  fleet-root-or-ref = fleet-root-or-ref or fleet-root
  if fleet-root-or-ref: return fleet-root-or-ref
  // For the environment 'ARTEMIS_FLEET' wins.
  fleet-env := os.env.get "ARTEMIS_FLEET" or os.env.get "ARTEMIS_FLEET_ROOT"
  if fleet-env:
    ui.do --kind=Ui.DEBUG: | printer/Printer |
      printer.emit "Using fleet-root '$fleet-env' provided by environment variable."
    return fleet-env
  return "."

make-default_ --device-id/uuid.Uuid --config/Config --ui/Ui:
  config[CONFIG-DEVICE-DEFAULT-KEY] = "$device-id"
  config.write
  ui.info "Default device set to $device-id."
