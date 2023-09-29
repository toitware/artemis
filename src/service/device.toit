// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import system.storage
import system.firmware show is-validation-pending
import uuid

import .firmware
import .utils show deep-copy
import ..shared.json-diff show json-equals Modification

/**
A representation of the device we are running on.

This class abstracts away the current state and configuration
  of the device.
*/
class Device:
  /** UUID used to ensure that the flash's data is actually from us. */
  static FLASH-ENTRY-UUID_ ::= "ccf4efed-6825-44e6-b71d-1aa118d43824"

  static FLASH-CURRENT-STATE_ ::= "current-state"
  static FLASH-CHECKPOINT_ ::= "checkpoint"
  static FLASH-REPORT-STATE-CHECKSUM_ ::= "report-state-checksum"
  flash_/storage.Bucket ::= storage.Bucket.open --flash "toit.io/artemis"

  // We store the information that contains timestamps in RAM,
  // so it clears when the timestamps are invalidated due to
  // loss of power. If we ever want to store these in flash
  // instead, we need to manually invalidate them when a new
  // monotonic clock phase starts.
  static RAM-CHECK-IN-LAST_ ::= "check-in-last"
  static RAM-SYNCHRONIZED-LAST_ ::= "synchronized-last"
  static RAM-SCHEDULER-JOB-STATES_ ::= "scheduler-job-states"
  ram_/storage.Bucket ::= storage.Bucket.open --ram "toit.io/artemis"

  /**
  The ID of the device.

  This ID was chosen during provisioning and is unique within
    a specific broker.
  */
  id/uuid.Uuid

  /**
  The hardware ID of the device.

  This ID was chosen during provisioning and is globally unique.
  */
  hardware-id/uuid.Uuid

  /**
  The organization ID of the device.
  */
  organization-id/uuid.Uuid

  /**
  The configuration as given by the firmware.

  This is the configuration the device was booted with.
  Unless the $current-state has a different "firmware" entry, this will
    also be the configuration the device will use when rebooted again.
  */
  firmware-state/Map

  /**
  The current configuration of the device.

  This is the configuration the device is currently running with.
  May return null, if the current configuration is the same as the
    $firmware-state.

  Note that the "firmware" entry in this map must always be equal to
    the "firmware" entry in the $firmware-state.

  If a new firmware has been installed, the $pending-firmware is set
    to that firmware.
  */
  current-state/Map := ?

  // We keep track of whether the current state can be modified.
  // We don't want to modify the firmware state and a state read
  // directly from the flash contains lists and maps that cannot
  // be modified.
  current-state-is-modifiable_/bool := false

  /**
  The firmware that is installed, but not yet running.
  */
  pending-firmware/string? := null

  /**
  The checksum of the last reported state.
  */
  report-state-checksum_/ByteArray? := null

  constructor --.id --.hardware-id --.organization-id --.firmware-state/Map:
    current-state = firmware-state
    load_

  /**
  Informs the device that the firmware has been validated.

  At this point the device is free to discard older information from the
    previous firmware.
  */
  firmware-validated -> none:
    flash-store_ FLASH-CURRENT-STATE_ null

  /**
  Whether the current state is modified and thus different from
    the firmware state.
  */
  is-current-state-modified -> bool:
    return not identical current-state firmware-state

  /**
  The current max-offline as a Duration.
  */
  max-offline -> Duration?:
    max-offline-s/int? := current-state.get "max-offline"
    if not max-offline-s: return null
    return Duration --s=max-offline-s

  /**
  The current firmware.

  This is the firmware the device is currently running with.
  The $current-state might already have a different firmware
    which would be executed after a reboot.
  */
  firmware -> string:
    return firmware-state["firmware"]

  /**
  Sets the max-offline of the current state.
  */
  state-set-max-offline new-max-offline/Duration?:
    state := current-state-modifiable_
    if new-max-offline and new-max-offline > Duration.ZERO:
      state["max-offline"] = new-max-offline.in-s
    else:
      state.remove "max-offline"
    simplify-and-store_

  /**
  Removes the container with the given $name from the current state.
  */
  state-container-uninstall name/string:
    state := current-state-modifiable_
    state["apps"].remove name
    simplify-and-store_

  /**
  Adds or updates the container with the given $name and $description in the current state.
  */
  state-container-install-or-update name/string description/Map:
    state := current-state-modifiable_
    apps := state.get "apps" --init=: {:}
    apps[name] = description
    simplify-and-store_

  /**
  Sets the firmware of the current state.

  This only marks the current state as having the new firmware installed.
    A reboot is required to actually use the new firmware.
  */
  state-firmware-update new/string:
    pending-firmware = new

  /**
  Get the checksum of the last state report.
  */
  report-state-checksum -> ByteArray?:
    return report-state-checksum_

  /**
  Sets the checksum of the last state report.
  */
  report-state-checksum= value/ByteArray -> none:
    flash-store_ FLASH-REPORT-STATE-CHECKSUM_ value
    report-state-checksum_ = value

  /**
  Gets the last check-in state (if any).
  */
  check-in-last -> Map?:
    return ram-load_ RAM-CHECK-IN-LAST_

  /**
  Stores the last check-in state in memory that is preserved across
    deep sleeping.
  */
  check-in-last-update value/Map -> none:
    ram-store_ RAM-CHECK-IN-LAST_ value

  /**
  Gets the scheduler jobs state information.
  */
  scheduler-job-states -> Map:
    stored := ram-load_ RAM-SCHEDULER-JOB-STATES_
    return stored is Map ? stored : {:}

  /**
  Stores the scheduler jobs state information in memory that
    is preserved across deep sleeping.
  */
  scheduler-job-states-update value/Map? -> none:
    ram-store_ RAM-SCHEDULER-JOB-STATES_ value

  /**
  Get the time of the last successful synchronization.
  */
  synchronized-last-us -> int?:
    return ram-load_ RAM-SYNCHRONIZED-LAST_

  /**
  Stores the time of the last successful synchronization in
    memory that is preserved across deep sleeping.
  */
  synchronized-last-us-update value/int -> none:
    ram-store_ RAM-SYNCHRONIZED-LAST_ value

  /**
  Gets the last checkpoint (if any) for the firmware update
    from $old to $new.
  */
  checkpoint --old/Firmware --new/Firmware -> Checkpoint?:
    value := flash-load_ FLASH-CHECKPOINT_
    if value is List and value.size == 6 and
        old.checksum == value[0] and
        new.checksum == value[1]:
      return Checkpoint
          --old-checksum=old.checksum
          --new-checksum=new.checksum
          --read-part-index=value[2]
          --read-offset=value[3]
          --write-offset=value[4]
          --write-skip=value[5]
    // If we find an oddly shaped entry in the flash, we might as
    // well clear it out eagerly.
    checkpoint-update null
    return null

  /**
  Updates the checkpoint information stored in flash.
  */
  checkpoint-update checkpoint/Checkpoint? -> none:
    value := checkpoint and [
      checkpoint.old-checksum,
      checkpoint.new-checksum,
      checkpoint.read-part-index,
      checkpoint.read-offset,
      checkpoint.write-offset,
      checkpoint.write-skip
    ]
    flash-store_ FLASH-CHECKPOINT_ value

  /**
  Get the current state in a modifiable form.
  */
  current-state-modifiable_ -> Map:
    if not current-state-is-modifiable_:
      current-state = deep-copy current-state
      current-state-is-modifiable_ = true
    return current-state

  /**
  Loads the states from flash.
  */
  load_ -> none:
    stored-current-state := flash-load_ FLASH-CURRENT-STATE_
    if stored-current-state:
      if stored-current-state["firmware"] == firmware-state["firmware"]:
        modification/Modification? := Modification.compute --from=firmware-state --to=stored-current-state
        if modification:
          log.debug "current state is changed" --tags={"changes": Modification.stringify modification}
          current-state = stored-current-state
      else:
        // At this point we don't clear the current state in the flash yet.
        // If the firmware is not validated, we might roll back, and then continue using
        // the old "current" state.
        if not is-validation-pending:
          log.error "current state has different firmware than firmware state"
    report-state-checksum_ = flash-load_ FLASH-REPORT-STATE-CHECKSUM_

  /**
  Stores the states into the flash after simplifying them.

  If the current state is the same as the firmware state sets it to null.
  */
  simplify-and-store_ -> none:
    if current-state and json-equals current-state firmware-state:
      current-state = firmware-state
      current-state-is-modifiable_ = false

    if is-validation-pending:
      log.error "validation still pending in simplify_and_store_"

    flash-store_ FLASH-CURRENT-STATE_ current-state

  flash-load_ key/string -> any:
    entry := flash_.get key
    if entry is not Map: return null
    if (entry.get "uuid") != FLASH-ENTRY-UUID_: return null
    return entry["data"]

  flash-store_ key/string value/any -> none:
    if value == null:
      flash_.remove key
    else:
      flash_[key] = { "uuid": FLASH-ENTRY-UUID_, "data": value }

  ram-load_ key/string -> any:
    return ram_.get key

  ram-store_ key/string value/any -> none:
    if value == null:
      ram_.remove key
    else:
      ram_[key] = value
