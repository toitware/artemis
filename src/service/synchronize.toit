// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor
import uuid
import reader show SizedReader UNEXPECTED_END_OF_READER_EXCEPTION
import system.containers

import .applications
import .jobs
import .mediator_service
import .status

import ..shared.device show Device
import ..shared.json_diff show Modification

// TODO(kasper): Move this elsewhere?
import bytes
import esp32
import crypto.sha256
import system.firmware
import encoding.ubjson
import encoding.base64
import encoding.hex  // Temporary.
import binary show LITTLE_ENDIAN
import ..shared.utils.patch

validate_firmware / bool := firmware.is_validation_pending

class SynchronizeJob extends Job implements EventHandler:
  static ACTION_NOP_/Lambda ::= :: null

  config_/Map := {:}

  logger_/log.Logger
  device_/Device
  applications_/ApplicationManager
  mediator_/MediatorService

  // We limit the capacity of the actions channel to avoid letting
  // the connect task build up too much work.
  actions_ ::= monitor.Channel 1

  // We cache the max-offline setting to avoid parsing it over and
  // over again. It is also stored in the configuration, so it is
  // also possible to fetch it from there.
  max_offline_/Duration? := null

  constructor logger/log.Logger .device_ .applications_ .mediator_ --firmware/string?=null:
    logger_ = logger.with_name "synchronize"
    if firmware: config_["firmware"] = firmware
    super "synchronize"

  schedule now/JobTime -> JobTime?:
    if not last_run or not max_offline_: return now
    return min (report_status_schedule now) (last_run + max_offline_)

  commit config/Map actions/List -> Lambda:
    return ::
      actions.do: it.call
      logger_.info "updating config" --tags={ "from": config_ , "to": config }
      config_ = config

  // TODO(kasper): For now, we make it look like we've updated
  // the firmware to avoid fetching the firmware over and over
  // again. We should probably replace this with something that
  // automatically populates our configuration with the right
  // firmware id on boot.
  fake_update_firmware id/string -> none:
    config_["firmware"] = id

  run -> none:
    logger_.info "connecting" --tags={"device": device_.id}
    mediator_.connect --device_id=device_.id --callback=this: | resources/ResourceManager |
      logger_.info "connected" --tags={"device": device_.id}
      while true:
        lambda/Lambda? := null
        catch: with_timeout report_status_timeout: lambda = actions_.receive
        if not lambda: break
        lambda.call
        if actions_.size > 0: continue

        // We only handle incomplete applications when we're done processing
        // the other actions. This means that we prioritize firmware updates
        // and configuration changes over fetching applications.
        if applications_.any_incomplete:
          assert: actions_.size == 0  // No issues with getting blocked on send.
          actions_.send (action_app_fetch_ resources)
          continue

        // We've successfully connected to the network, so we consider
        // the current firmware functional. Go ahead and validate the
        // firmware if requested to do so.
        if validate_firmware:
          if firmware.validate:
            logger_.info "firmware update validated after connecting to network"
            validate_firmware = false
          else:
            logger_.error "firmware update failed to validate"

        if max_offline_:
          logger_.info "synchronized" --tags={"max-offline": max_offline_}
          break
        logger_.info "synchronized"

      logger_.info "disconnecting" --tags={"device": device_.id}

  handle_nop -> none:
    actions_.send ACTION_NOP_

  handle_update_config new_config/Map resources/ResourceManager -> none:
    modification/Modification? := Modification.compute --from=config_ --to=new_config
    if not modification:
      handle_nop
      return
    logger_.info "config changed: $(Modification.stringify modification)"

    modification.on_value "firmware"
        --added=: | value |
          logger_.info "update firmware to $value"
          handle_firmware_update_ resources value
          return
        --removed=: | value |
          logger_.error "firmware information was lost (was: $value)"
        --updated=: | from to |
          logger_.info "update firmware from $from to $to"
          handle_firmware_update_ resources to
          return

    bundle := []
    modification.on_map "apps"
        --added=: | key value |
          // An app just appeared in the configuration. If we got an id
          // for it, we install it.
          id ::= value is Map ? value.get Application.CONFIG_ID : null
          if id: bundle.add (action_app_install_ key id)
        --removed=: | key value |
          // An app disappeared completely from the configuration. We
          // uninstall it, if we got an id for it.
          id := value is string ? value : null
          id = id or value is Map ? value.get Application.CONFIG_ID : null
          if id: bundle.add (action_app_uninstall_ key id)
        --modified=: | key nested/Modification |
          value ::= new_config["apps"][key]  // TODO(kasper): This feels unfortunate.
          id ::= value is Map ? value.get Application.CONFIG_ID : null
          handle_update_app_ bundle key id nested

    modification.on_value "max-offline"
        --added   =: bundle.add (action_set_max_offline_ it)
        --removed =: bundle.add (action_set_max_offline_ null)

    actions_.send (commit new_config bundle)

  handle_firmware_update_ resources/ResourceManager id/string -> none:
    actions_.send (action_firmware_update_ resources id)

  handle_update_app_ bundle/List name/string id/string? modification/Modification -> none:
    modification.on_value "id"
        --added=: | value |
          // An application that existed in the configuration suddenly
          // got an id. Great. Let's install it!
          bundle.add (action_app_install_ name value)
          return
        --removed=: | value |
          // Woops. We just lost the id for an application we already
          // had in the configuration. We need to uninstall.
          bundle.add (action_app_uninstall_ name value)
          return
        --updated=: | from to |
          // An application had its id (the code) updated. We uninstall
          // the old version and install the new one.
          bundle.add (action_app_uninstall_ name from)
          bundle.add (action_app_install_ name to)
          return
    // The configuration for the application was updated, but we didn't
    // change its id, so the code for it is still valid. We add a pending
    // action to make sure we let the application of the change possibly
    // by restarting it.
    if id: bundle.add (action_app_update_ name id)

  action_app_install_ name/string id/string -> Lambda:
    return :: applications_.install (Application name id)

  action_app_uninstall_ name/string id/string -> Lambda:
    return ::
      application/Application? := applications_.get id
      if application: applications_.uninstall application

  action_app_update_ name/string id/string -> Lambda:
    return ::
      application/Application? := applications_.get id
      if application: applications_.update application

  action_app_fetch_ resources/ResourceManager -> Lambda:
    return ::
      incomplete/Application? ::= applications_.first_incomplete
      if incomplete:
        resources.fetch_image incomplete.id: | reader/SizedReader |
          applications_.complete incomplete reader

  action_set_max_offline_ value/any -> Lambda:
    return :: max_offline_ = (value is int) ? Duration --s=value : null

  action_firmware_update_ resources/ResourceManager x/string -> Lambda:
    return ::
      // TODO(kasper): Introduce run-levels for jobs and make sure we're
      // not running a lot of other stuff while we update the firmware.
      old_update := ubjson.decode (base64.decode config_["firmware"])
      old_firmware := ubjson.decode (ubjson.decode old_update["config"])["firmware"]
      update := ubjson.decode (base64.decode x)
      config_encoded := update["config"]
      config := ubjson.decode config_encoded
      firmwarex := ubjson.decode config["firmware"]
      grand_total_size := firmwarex.last["to"] + update["checksum"].size

      logger_.info "firmware update" --tags={"size": grand_total_size}

      elapsed := Duration.of:
        firmware.map: | old/firmware.FirmwareMapping? |
          // TODO(kasper): Remember to close the writer in the patcher if
          // everything fails.
          patcher := FirmwarePatcher logger_ old grand_total_size
          firmwarex.size.repeat: | index/int |
            part := firmwarex[index]
            type := part.get "type"

            if type == "config":
              patcher.write_config part config_encoded
            else:
              // TODO(kasper): This should be based on name/type -- not index.
              patcher.write_part part resources old_firmware[index]

          patcher.write_checksum update["checksum"]

      logger_.info "firmware update: 100%" --tags={"elapsed": elapsed}
      fake_update_firmware x  // TODO(kasper): Is this still fake?
      firmware.upgrade

class FirmwarePatcher implements PatchObserver:
  logger_/log.Logger
  next_print_offset_/int := 0

  // old
  old_/firmware.FirmwareMapping?

  // new
  writer_/firmware.FirmwareWriter := ?
  total_size_/int
  offset_/int := ?
  skip_/int := ?

  // committed
  image_offset_checkpointed_/int := 0
  image_skip_checkpointed_/int := 0
  patch_offset_checkpointed_/int := -1

  // uncommitted
  remaining_/int := 0
  prepared_patch_offset_/int := -1
  prepared_image_skip_/int := -1

  constructor .logger_ .old_ size/int:
    // TODO(kasper): Properly initialize skip and offset if
    // we're resuming after powerloss or dropped connection.
    offset_ = 0
    skip_ = 0
    total_size_ = size
    writer_ = firmware.FirmwareWriter offset_ size

  write_config part/Map config/ByteArray -> none:
    padded_size := part["to"] - part["from"]
    size := ByteArray 4
    LITTLE_ENDIAN.put_uint32 size 0 config.size
    on_write size
    on_write config
    pad_ padded_size - (config.size + 4)

  write_checksum checksum/ByteArray -> none:
    on_write checksum
    writer_.commit

  write_part part/Map resources/ResourceManager existing/Map -> none:
    new_hash := part["hash"]
    old_hash := existing["hash"]

    old/firmware.FirmwareMapping? := null
    if old_:
      old_from := existing["from"]
      old_to := existing["to"]
      old = old_[old_from..old_to]

    if old and new_hash == old_hash:
      chunk := ByteArray 512
      List.chunk_up 0 old.size chunk.size: | from to size |
        old.copy from to --into=chunk
        on_write chunk[0..size]
      return

    new_id := base64.encode new_hash --url_mode
    resource := null
    if old:
      old_id := base64.encode old_hash --url_mode
      resource = "$new_id/$old_id"
    else:
      resource = "$new_id/none"

    // Reset the patch state.
    patch_size := 0
    patch_offset_checkpointed_ = 0

    resources.fetch_firmware resource: | reader/SizedReader offset/int total_size/int |
      // TODO(kasper): This isn't very elegant. We need the patch size
      // to determine when we're done with the patch, but we only get
      // it passed on the first block invocation.
      if offset == 0: patch_size = total_size
      apply_ reader old patch_size

  apply_ reader/SizedReader old/firmware.FirmwareMapping? patch_size/int -> int:
    start := patch_offset_checkpointed_
    binary_patcher := Patcher reader old --patch_offset=start
    exception := catch --unwind=(: it != UNEXPECTED_END_OF_READER_EXCEPTION or patch_offset_checkpointed_ == start):
      binary_patcher.patch this
    if not exception: return patch_size

    // Go back to last checkpoint.
    logger_.info "going back to checkpoint" --tags={"offset": image_offset_checkpointed_, "skip": image_skip_checkpointed_}
    remaining_ = 0
    skip_ = image_skip_checkpointed_
    offset_ = image_offset_checkpointed_ - skip_
    writer_.close
    writer_ = firmware.FirmwareWriter image_offset_checkpointed_ total_size_
    return patch_offset_checkpointed_

  pad_ padding/int -> none:
    write_ 0 padding: | x y | writer_.pad (y - x)

  on_write data from/int=0 to/int=data.size -> none:
    write_ from to: | x y | writer_.write data[x..y]

  write_ from/int to/int [write] -> none:
    // Skip over already written parts.
    to_skip := min skip_ (to - from)
    if to_skip > 0:
      skip_ -= to_skip
      offset_ += to_skip
      if skip_ > 0: return
      from += to_skip

    // Then try to get to a checkpoint.
    to_write := min remaining_ (to - from)
    if to_write > 0:
      write.call from (from + to_write)
      remaining_ -= to_write
      offset_ += to_write
      if remaining_ > 0: return
      commit_checkpoint
      from += to_write

    // Write the rest.
    write.call from to
    offset_ += to - from

    // Give us some nice progress tracking.
    if offset_ > next_print_offset_:
      percent := (offset_ * 100) / total_size_
      logger_.info "firmware update: $(%3d percent)%"
      next_print_offset_ = offset_ + 64 * 1024

  on_new_checksum hash/ByteArray -> none:
    unreachable

  on_size size/int -> none:
    // Do nothing.

  on_checkpoint patch_offset/int -> none:
    if skip_ > 0 or remaining_ > 0: return
    prepared_patch_offset_ = patch_offset
    align := offset_ & 0xf
    prepared_image_skip_ = align == 0 ? 0 : 16 - align
    if prepared_image_skip_ == 0:
      commit_checkpoint
    else:
      remaining_ = prepared_image_skip_

  commit_checkpoint -> none:
    writer_.flush
    image_offset_checkpointed_ = offset_
    patch_offset_checkpointed_ = prepared_patch_offset_
    image_skip_checkpointed_ = prepared_image_skip_
    prepared_patch_offset_ = -1
    prepared_image_skip_ = -1
