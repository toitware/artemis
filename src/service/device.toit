// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import system.storage
import system.firmware show is_validation_pending
import ..shared.json_diff show json_equals

/** UUID used to ensure that the bucket's data is actually from us. */
BUCKET_UUID_ ::= "ccf4efed-6825-44e6-b71d-1aa118d43824"

decode_bucket_entry_ entry -> any:
  if entry is not Map: return null
  if (entry.get "uuid") != BUCKET_UUID_: return null
  return entry["data"]

encode_bucket_entry_ data -> Map:
  return { "uuid": BUCKET_UUID_, "data": data }

/**
A representation of the device we are running on.

This class abstracts away the current configuration of the device.
*/
class Device:
  bucket_/storage.Bucket

  /**
  The hardware ID of the device.

  This ID was chosen during provisioning and is unique.
  */
  id/string

  /**
  The organization ID of the device.
  */
  organization_id/string

  /**
  The configuration as given by the firmware.

  This is the configuration the device was booted with.
  Unless the $current_state has a different "firmware" entry, this will
    also be the configuration the device will use when rebooted again.
  */
  firmware_state/Map

  /**
  The current configuration of the device.

  This is the configuration the device is currently running with.
  May return null, if the current configuration is the same as the
    $firmware_state.

  Note that the "firmware" entry in this map must always be equal to
    the "firmware" entry in the $firmware_state.

  If a new firmware has been installed, the $pending_firmware is set
    to that firmware.
  */
  current_state/Map? := null

  /**
  The configuration the device tries to reach.

  This is the configuration the device is trying to reach.
  After getting a new configuration from the broker, the device
    applies the changes that are requested. Some of these
    changes can be applied immediately (like changing the max-offline),
    but some others might take more time (like installing a new
    programs or firmware).

  May return null, if the goal state is the same as the
    $current_state.
  */
  goal_state/Map? := null

  /**
  The firmware that is installed, but not yet running.
  */
  pending_firmware/string? := null

  constructor --.id --.organization_id --.firmware_state/Map:
    bucket_ = storage.Bucket.open --flash "toit.io/artemis/device_states"
    stored_current_state := decode_bucket_entry_ (bucket_.get "current_state")
    if stored_current_state:
      if stored_current_state["firmware"] == firmware_state["firmware"]:
        log.debug "using stored current state" --tags={ "state": stored_current_state }
        current_state = stored_current_state
      else:
        // At this point we don't clear the current state in the bucket yet.
        // If the firmware is not validated, we might roll back, and then continue using
        // the old "current" state.
        if not is_validation_pending:
          log.error "current state has different firmware than firmware state"
        current_state = null
    goal_state = decode_bucket_entry_ (bucket_.get "goal_state")

  /**
  Informs the device that the firmware has been validated.

  At this point the device is free to discard older information from the
    previous firmware.
  */
  firmware_validated:
    bucket_.remove "current_state"

  /**
  The current max-offline as a Duration.
  */
  max_offline -> Duration?:
    max_offline_s/int? := null
    if current_state: max_offline_s = current_state.get "max-offline"
    else: max_offline_s = firmware_state.get "max-offline"
    if not max_offline_s: return null
    return Duration --s=max_offline_s

  /**
  The current firmware.

  This is the firmware the device is currently running with.
  The $current_state might already have a different firmware
    which would be executed after a reboot.
  */
  firmware -> string:
    return firmware_state["firmware"]

  /**
  Sets the max-offline of the current state.
  */
  state_set_max_offline new_max_offline/Duration?:
    if not current_state: current_state = deep_copy_ firmware_state
    if new_max_offline and new_max_offline > Duration.ZERO:
      current_state["max-offline"] = new_max_offline.in_s
    else:
      current_state.remove "max-offline"
    simplify_and_store_

  /**
  Removes the program with the given $name from the current state.
  */
  state_app_uninstall name/string:
    if not current_state: current_state = deep_copy_ firmware_state
    current_state["apps"].remove name
    simplify_and_store_

  /**
  Adds or updates the program with the given $name and $description in the current state.
  */
  state_app_install_or_update name/string description/Map:
    if not current_state: current_state = deep_copy_ firmware_state
    apps := current_state.get "apps" --init=: {:}
    apps[name] = description
    simplify_and_store_

  /**
  Sets the firmware of the current state.

  This only marks the current state as having the new firmware installed.
    A reboot is required to actually use the new firmware.
  */
  state_firmware_update new/string:
    pending_firmware = new

  /**
  Writes the states into the bucket after simplifying them.

  If the goal state is the same as the current state sets it to null.
  If the current state is the same as the firmware state sets it to null.
  */
  simplify_and_store_:
    if goal_state and current_state:
      // For simplicity we don't require goal states to contain firmware
      // information.
      if not goal_state.contains "firmware":
        goal_state["firmware"] = current_state["firmware"]
      if json_equals goal_state current_state:
        goal_state = null

    if current_state and json_equals current_state firmware_state:
      current_state = null

    if is_validation_pending:
      log.error "validation still pending in simplify_and_store_"

    bucket_["current_state"] = encode_bucket_entry_ current_state
    bucket_["goal_state"] = encode_bucket_entry_ goal_state

deep_copy_ o/any -> any:
  if o is Map:
    return (o as Map).map: | _ value | deep_copy_ value
  else if o is List:
    return (o as List).map: deep_copy_ it
  else:
    return o
