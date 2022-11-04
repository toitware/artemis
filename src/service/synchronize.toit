// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor
import uuid
import reader show SizedReader
import system.containers
import system.firmware

import .applications
import .firmware_update
import .jobs
import .mediator_service
import .status

import ..shared.device show Device
import ..shared.json_diff show Modification

validate_firmware / bool := firmware.is_validation_pending

class SynchronizeJob extends Job implements EventHandler:
  static ACTION_NOP_/Lambda ::= :: null

  firmware_/string
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

  constructor logger/log.Logger .device_ .applications_ .mediator_ --firmware/string:
    logger_ = logger.with_name "synchronize"
    firmware_ = firmware
    config_["firmware"] = firmware
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

      // TODO(kasper): Move this status reporting elsewhere. We shouldn't do
      // it all the time for performance and bandwidth reasons.
      resources.report_status device_.id {
        "sdk"      : vm_sdk_version,
        "firmware" : firmware_,
      }

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
        mediator_.on_idle

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

  handle_firmware_update_ resources/ResourceManager new/string -> none:
    actions_.send (action_firmware_update_ resources new)

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

  action_firmware_update_ resources/ResourceManager new/string -> Lambda:
    return ::
      // TODO(kasper): Introduce run-levels for jobs and make sure we're
      // not running a lot of other stuff while we update the firmware.
      old := config_["firmware"]
      firmware_update logger_ resources --old=old --new=new
      fake_update_firmware new  // TODO(kasper): Is this still fake?
      firmware.upgrade
