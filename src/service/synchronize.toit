// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor
import uuid
import reader show SizedReader
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
import reader show BufferedReader
import crypto.sha256
import system.firmware
import encoding.ubjson
import encoding.base64
import encoding.hex
import binary show LITTLE_ENDIAN
import ..shared.utils.patch

OLD_BYTES_HACK/ByteArray := #[]

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

  constructor logger/log.Logger .device_ .applications_ .mediator_ --initial_firmware/ByteArray?=null:
    logger_ = logger.with_name "synchronize"
    if initial_firmware: config_["firmware"] = initial_firmware.to_string_non_throwing
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
      old_firmware := ubjson.decode old_update["config"]["firmware"]
      update := ubjson.decode (base64.decode x)
      config_encoded := update["config"]
      config := ubjson.decode config_encoded
      firmware := ubjson.decode config["firmware"]
      grand_total_size := firmware.last["to"]

      collected := []
      elapsed := Duration.of:
        firmware.size.repeat: | index/int |
          part := firmware[index]
          type := part.get "type"
          if type == "config":
            config_bytes := ByteArray part["to"] - part["from"]
            LITTLE_ENDIAN.put_uint32 config_bytes 0 config_encoded.size
            config_bytes.replace 4 config_encoded
            collected.add config_bytes
            continue.repeat

          id := base64.encode part["hash"] --url_mode
          // TODO(kasper): This should be based on name/type -- not index.
          from_id := base64.encode old_firmware[index]["hash"] --url_mode

          from_from := old_firmware[index]["from"]
          from_to := old_firmware[index]["to"]

          resource := null
          old := null
          if from_to <= OLD_BYTES_HACK.size:
            old = OLD_BYTES_HACK[from_from..from_to]
            if id == from_id:
              collected.add old
              continue.repeat
            resource = "$id/$from_id"
          else:
            resource = "$id/none"
            old = #[]

          patcher/FirmwarePatcher? := null
          try:
            resources.fetch_firmware resource: | reader/SizedReader offset/int total_size/int |
              if offset == 0:
                if index == 0: logger_.info "firmware update" --tags={"id": id, "size": grand_total_size}
                grand_total_offset := index == 0 ? 0 : firmware[index - 1]["to"]
                patcher = FirmwarePatcher logger_ total_size grand_total_offset grand_total_size
              patcher.apply reader old
            collected.add patcher.writer_.bytes
          finally:
            if patcher: patcher.close

      logger_.info "firmware update: 100%" --tags={"elapsed": elapsed}
      collected.add update["checksum"]
      all := ByteArray 0
      collected.do: all += it
      print "Got a grand total of $all.size bytes"
      sha := sha256.Sha256
      sha.add all[..all.size - 32]
      print "Computed checksum = $(hex.encode sha.get)"
      print "Provided checksum = $(hex.encode all[all.size - 32..])"

      // TODO(kasper): It would be great if we could also restart the Artemis
      // service here for testing purposes.
      fake_update_firmware x
      if platform == PLATFORM_FREERTOS: esp32.deep_sleep (Duration --ms=100)

class FirmwarePatcher implements PatchObserver:
  logger_/log.Logger

  total_size_/int
  total_offset_/int

  patch_size_/int
  patch_offset_checkpointed_/int := 0

  image_size_/int? := null
  image_offset_/int := 0
  image_offset_checkpointed_/int := 0

  writer_ := null

  constructor .logger_ .patch_size_ .total_offset_ .total_size_:
    // Do nothing.

  apply reader/SizedReader old/ByteArray -> int:
    if image_size_:
      if platform == PLATFORM_FREERTOS:
        writer_ = firmware.FirmwareWriter image_offset_checkpointed_ image_size_
      else:
        writer_ = FakeFirmwareWriter.view writer_.bytes image_offset_checkpointed_ image_size_
      image_offset_ = image_offset_checkpointed_
    try:
      binary_patcher := Patcher (BufferedReader reader) old
          --patch_offset=patch_offset_checkpointed_
      catch --trace --unwind=(: true):
        binary_patcher.patch this
    finally: | is_exception _ |
      if writer_:
        // TODO(kasper): Handle exception in commit call.
        if not is_exception: writer_.commit
        writer_.close
      return is_exception
          ? patch_offset_checkpointed_  // Continue after checkpoint.
          : patch_size_                 // Done!

  close:
    if not writer_: return
    writer_.close
    writer_ = null

  on_write data from/int=0 to/int=data.size -> none:
    if writer_: writer_.write data[from..to]
    image_offset_ += to - from

  on_new_checksum hash/ByteArray -> none:
    unreachable

  on_size size/int -> none:
    image_size_ = size
    if platform == PLATFORM_FREERTOS:
      writer_ = firmware.FirmwareWriter 0 size
    else:
      writer_ = FakeFirmwareWriter size
    image_offset_ = 0

  on_checkpoint patch_offset/int -> none:
    percent := (image_offset_ + total_offset_) * 100 / total_size_
    logger_.info "firmware update: $(%3d percent)%"
    patch_offset_checkpointed_ = patch_offset
    image_offset_checkpointed_ = image_offset_

class FakeFirmwareWriter:
  bytes/ByteArray
  view/ByteArray
  cursor_ := 0

  constructor size/int:
    bytes = ByteArray size
    view = bytes

  constructor.view .bytes from/int to/int:
    view = bytes[from..to]

  write data/ByteArray:
    view.replace cursor_ data
    cursor_ += data.size

  commit -> none:
    // Yes, yes.

  close -> none:
    // Si, si.
