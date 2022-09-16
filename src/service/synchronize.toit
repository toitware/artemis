// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor
import uuid
import reader show SizedReader

import system.containers

import .applications
import .jobs
import .resources

import ..shared.connect
import ..shared.json_diff show Modification

abstract class SynchronizeJob extends Job:
  static ACTION_NOP_/Lambda ::= :: null

  logger_/log.Logger
  device/Device
  applications_/ApplicationManager

  // We limit the capacity of the actions channel to avoid letting
  // the connect task build up too much work.
  actions_ ::= monitor.Channel 1

  // We cache the max-offline setting to avoid parsing it over and
  // over again. It is also stored in the configuration, so it is
  // also possible to fetch it from there.
  max_offline_/Duration? := null

  constructor logger/log.Logger .device .applications_:
    logger_ = logger.with_name "synchronize"
    super "synchronize"

  schedule now/JobTime -> JobTime?:
    if not last_run or not max_offline_: return now
    return last_run + max_offline_

  abstract connect [block] -> none
  abstract commit config/Map bundle/List -> Lambda

  run -> none:
    logger_.info "connecting" --tags={"device": device.name}
    connect: | resources/ResourceManager |
      logger_.info "connected" --tags={"device": device.name}
      while true:
        actions_.receive.call
        if actions_.size > 0: continue

        // We only handle incomplete applications when we're done processing
        // the other actions. This means that we prioritize firmware updates
        // and configuration changes over fetching applications.
        if applications_.any_incomplete:
          assert: actions_.size == 0  // No issues with getting blocked on send.
          actions_.send (action_app_fetch_ resources)
          continue

        logger_.info "synchronized"
        if max_offline_:
          logger_.info "disconnecting" --tags={"duration": max_offline_}
          return

  handle_nop -> none:
    actions_.send ACTION_NOP_

  handle_update_config from/Map to/Map -> none:
    modification/Modification? := Modification.compute --from=from --to=to
    if not modification: return

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
          value ::= to["apps"][key]  // TODO(kasper): This feels unfortunate.
          id ::= value is Map ? value.get Application.CONFIG_ID : null
          handle_update_app_ bundle key id nested

    modification.on_value "max-offline"
        --added   =: bundle.add (action_set_max_offline_ it)
        --removed =: bundle.add (action_set_max_offline_ null)

    actions_.send (commit to bundle)

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
        resources.fetch_resource incomplete.path: | reader/SizedReader |
          applications_.complete incomplete reader

  action_set_max_offline_ value/any -> Lambda:
    return ::
      max_offline_ = (value is int) ? Duration --s=value : null
