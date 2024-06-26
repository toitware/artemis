// Copyright (C) 2022 Toitware ApS. All rights reserved.

import uuid
import .firmware

class Device:
  /**
  The hardware ID of the device.

  On the Artemis server, this is the primary key and simply called "id".
  The hardware ID is generated by the Artemis server.

  This ID is generally *not* shared with the user.
  */
  hardware-id/uuid.Uuid

  /**
  The device ID.

  This ID is the one under which users identify a device.
  It's also called "alias" in the Artemis server.
  */
  id/uuid.Uuid

  /**
  The organization ID of the device.

  The ID in which organization the device is registered in.
  */
  organization-id/uuid.Uuid

  constructor --.hardware-id --.id --.organization-id:

/**
A detailed version of the $Device class.
*/
class DeviceDetailed extends Device:
  /**
  The state the device should try to reach.

  This is the configuration that the broker currently sends to the device.
  May be null if the device was never instructed to change state.
  */
  goal/Map?

  /**
  The goal state as reported by the device.

  This might be different from the actual goal state if the device either
    didn't yet receive the new goal state, or if the device didn't report its
    current state yet.

  May be null if the device has not reported a state yet, or if
    the device already applied all the changes.
  */
  reported-state-goal/Map?

  /**
  The current state of the device.

  May be null if the device has not reported a state yet, or if
    the device's firmware state is equal to the current state.
  */
  reported-state-current/Map?

  /**
  The device's firmware state.
  May be null if the device has not reported a state yet.
  */
  reported-state-firmware/Map?

  /**
  The firmware that is installed but not yet running.

  The device has updated its firmware but has not yet rebooted.
  */
  pending-firmware/string?

  /**
  Constructs a new detailed device from the current goal and the
    reported state.
  */
  constructor --.goal/Map? --state/Map?:
    assert: goal or state

    reported-state-goal = state and state.get "goal-state"
    reported-state-current = state and state.get "current-state"
    reported-state-firmware = state and state.get "firmware-state"
    pending-firmware = state and state.get "pending-firmware"

    initial-state := reported-state-firmware ? null : state
    local-organization-id := ?
    local-hardware-id := ?
    local-id := ?

    if initial-state:
      identity := initial-state["identity"]
      local-organization-id = uuid.parse identity["organization_id"]
      local-hardware-id = uuid.parse identity["hardware_id"]
      local-id = uuid.parse identity["device_id"]
    else:
      old-firmware := Firmware.encoded reported-state-firmware["firmware"]
      device := old-firmware.device-specific "artemis.device"
      local-organization-id = uuid.parse device["organization_id"]
      local-hardware-id = uuid.parse device["hardware_id"]
      local-id = uuid.parse device["device_id"]

    super --hardware-id=local-hardware-id --id=local-id --organization-id=local-organization-id

  pod-id-firmware -> uuid.Uuid?:
    return pod-id-from-state_ reported-state-firmware

  pod-id-current -> uuid.Uuid?:
    return pod-id-from-state_ reported-state-current

  pod-id-goal -> uuid.Uuid?:
    return pod-id-from-state_ reported-state-goal

  pod-id-from-state_ state/Map? -> uuid.Uuid?:
    if not state: return null
    if not state.contains "firmware": return null

    firmware := Firmware.encoded state["firmware"]
    return firmware.pod-id
