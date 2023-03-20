// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import system.storage
import system.firmware show is_validation_pending

import .firmware
import .utils show deep_copy
import ..shared.json_diff show json_equals Modification

/**
A representation of the device we are running on.

This class abstracts away the current state and configuration
  of the device.
*/
class Device:
  /** UUID used to ensure that the flash's data is actually from us. */
  static FLASH_ENTRY_UUID_ ::= "ccf4efed-6825-44e6-b71d-1aa118d43824"

  static FLASH_GOAL_STATE_ ::= "goal-state"
  static FLASH_CURRENT_STATE_ ::= "current-state"
  static FLASH_CHECKPOINT_ ::= "checkpoint"
  flash_/storage.Bucket ::= storage.Bucket.open --flash "toit.io/artemis"

  // We store the information that contains timestamps in RAM,
  // so it clears when the timestamps are invalidated due to
  // loss of power. If we ever want to store these in flash
  // instead, we need to manually invalidate them when a new
  // monotonic clock phase starts.
  static RAM_CHECK_IN_LAST_ ::= "check-in-last"
  static RAM_JOBS_RAN_LAST_END_ ::= "jobs-ran-last-end"
  ram_/storage.Bucket ::= storage.Bucket.open --ram "toit.io/artemis"

  /**
  The ID of the device.

  This ID was chosen during provisioning and is unique within
    a specific broker.
  */
  id/string

  /**
  The hardware ID of the device.

  This ID was chosen during provisioning and is globally unique.
  */
  hardware_id/string

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
  current_state/Map := ?

  // We keep track of whether the current state can be modified.
  // We don't want to modify the firmware state and a state read
  // directly from the flash contains lists and maps that cannot
  // be modified.
  current_state_is_modifiable_/bool := false

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

  constructor --.id --.hardware_id --.organization_id --.firmware_state/Map:
    current_state = firmware_state
    load_

  /**
  Informs the device that the firmware has been validated.

  At this point the device is free to discard older information from the
    previous firmware.
  */
  firmware_validated -> none:
    flash_store_ FLASH_CURRENT_STATE_ null

  /**
  Whether the current state is modified and thus different from
    the firmware state.
  */
  is_current_state_modified -> bool:
    return not identical current_state firmware_state

  /**
  The current max-offline as a Duration.
  */
  max_offline -> Duration?:
    max_offline_s/int? := current_state.get "max-offline"
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
    state := current_state_modifiable_
    if new_max_offline and new_max_offline > Duration.ZERO:
      state["max-offline"] = new_max_offline.in_s
    else:
      state.remove "max-offline"
    simplify_and_store_

  /**
  Removes the container with the given $name from the current state.
  */
  state_container_uninstall name/string:
    state := current_state_modifiable_
    state["apps"].remove name
    simplify_and_store_

  /**
  Adds or updates the container with the given $name and $description in the current state.
  */
  state_container_install_or_update name/string description/Map:
    state := current_state_modifiable_
    apps := state.get "apps" --init=: {:}
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
  Gets the last check-in state (if any).
  */
  check_in_last -> Map?:
    return ram_load_ RAM_CHECK_IN_LAST_

  /**
  Stores the last check-in state in memory that is preserved across
    deep sleeping.
  */
  check_in_last_update value/Map -> none:
    ram_store_ RAM_CHECK_IN_LAST_ value

  /**
  Gets a modifiable copy of the jobs ran last information.
  */
  jobs_ran_last_end_modifiable -> Map:
    stored := ram_load_ RAM_JOBS_RAN_LAST_END_
    return stored is Map ? (deep_copy stored) : {:}

  /**
  Stores the jobs ran last information in memory that is preserved
    across deep sleeping.
  */
  jobs_ran_last_end_update value/Map -> none:
    ram_store_ RAM_JOBS_RAN_LAST_END_ value

  /**
  Gets the last checkpoint (if any) for the firmware update
    from $old to $new.
  */
  checkpoint --old/Firmware --new/Firmware -> Checkpoint?:
    value := flash_load_ FLASH_CHECKPOINT_
    if value is List and value.size == 6 and
        old.checksum == value[0] and
        new.checksum == value[1]:
      return Checkpoint
          --old_checksum=old.checksum
          --new_checksum=new.checksum
          --read_part_index=value[2]
          --read_offset=value[3]
          --write_offset=value[4]
          --write_skip=value[5]
    // If we find an oddly shaped entry in the flash, we might as
    // well clear it out eagerly.
    checkpoint_update null
    return null

  /**
  Updates the checkpoint information stored in flash.
  */
  checkpoint_update checkpoint/Checkpoint? -> none:
    value := checkpoint and [
      checkpoint.old_checksum,
      checkpoint.new_checksum,
      checkpoint.read_part_index,
      checkpoint.read_offset,
      checkpoint.write_offset,
      checkpoint.write_skip
    ]
    flash_store_ FLASH_CHECKPOINT_ value

  /**
  Get the current state in a modifiable form.
  */
  current_state_modifiable_ -> Map:
    if not current_state_is_modifiable_:
      current_state = deep_copy current_state
      current_state_is_modifiable_ = true
    return current_state

  /**
  Loads the states from flash.
  */
  load_ -> none:
    stored_current_state := flash_load_ FLASH_CURRENT_STATE_
    if stored_current_state:
      if stored_current_state["firmware"] == firmware_state["firmware"]:
        modification/Modification? := Modification.compute --from=firmware_state --to=stored_current_state
        if modification:
          log.debug "current state is changed" --tags={"changes": Modification.stringify modification}
          current_state = stored_current_state
      else:
        // At this point we don't clear the current state in the flash yet.
        // If the firmware is not validated, we might roll back, and then continue using
        // the old "current" state.
        if not is_validation_pending:
          log.error "current state has different firmware than firmware state"
    goal_state = flash_load_ FLASH_GOAL_STATE_

  /**
  Stores the states into the flash after simplifying them.

  If the goal state is the same as the current state sets it to null.
  If the current state is the same as the firmware state sets it to null.
  */
  simplify_and_store_ -> none:
    if goal_state and json_equals goal_state current_state:
      goal_state = null

    if current_state and json_equals current_state firmware_state:
      current_state = firmware_state
      current_state_is_modifiable_ = false

    if is_validation_pending:
      log.error "validation still pending in simplify_and_store_"

    flash_store_ FLASH_CURRENT_STATE_ current_state
    flash_store_ FLASH_GOAL_STATE_ goal_state

  flash_load_ key/string -> any:
    entry := flash_.get key
    if entry is not Map: return null
    if (entry.get "uuid") != FLASH_ENTRY_UUID_: return null
    return entry["data"]

  flash_store_ key/string value/any -> none:
    if value == null:
      flash_.remove key
    else:
      flash_[key] = { "uuid": FLASH_ENTRY_UUID_, "data": value }

  ram_load_ key/string -> any:
    return ram_.get key

  ram_store_ key/string value/any -> none:
    if value == null:
      ram_.remove key
    else:
      ram_[key] = value
