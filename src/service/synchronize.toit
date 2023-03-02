// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor
import reader show SizedReader
import system.containers
import system.firmware

import .applications
import .firmware_update
import .jobs
import .brokers.broker
import .check_in

import .device
import ..shared.json_diff show Modification json_equals

validate_firmware / bool := firmware.is_validation_pending

class SynchronizeJob extends Job implements EventHandler:
  static ACTION_NOP_/Lambda ::= :: null

  logger_/log.Logger
  device_/Device
  applications_/ApplicationManager
  broker_/BrokerService

  // We limit the capacity of the actions channel to avoid letting
  // the connect task build up too much work.
  actions_ ::= monitor.Channel 1

  constructor logger/log.Logger .device_ .applications_ .broker_:
    logger_ = logger.with_name "synchronize"
    super "synchronize"

  schedule now/JobTime -> JobTime?:
    max_offline := device_.max_offline
    if not last_run or not max_offline: return now
    return min (check_in_schedule now) (last_run + max_offline)

  commit goal_state/Map actions/List -> Lambda:
    return ::
      current_state := device_.current_state or device_.firmware_state
      logger_.info "updating config" --tags={ "from": current_state , "to": goal_state }
      actions.do: it.call

  run -> none:
    logger_.info "connecting" --tags={"device": device_.id}
    broker_.connect --device_id=device_.id --callback=this: | resources/ResourceManager |
      logger_.info "connected" --tags={"device": device_.id}

      // TODO(florian): We don't need to report the status every time we
      // connect. We only need to do this the first time we connect or
      // if we know that the broker isn't up to date.
      report_status resources

      // The 'handle_goal' only pushes actions into the
      // 'actions_' channel.
      // This loop is responsible for actually executing the actions.
      // Note that some actions might create more actions. Specifically,
      // we expect a single 'commit' action for a configuration update.
      while true:
        lambda/Lambda? := null
        // The timeout is only relevant for the first iteration of the
        // loop, or when max-offline is not set. In all other cases
        // a 'break' will get us out of the loop.
        catch: with_timeout check_in_timeout: lambda = actions_.receive
        if not lambda:
          // No action (by 'handle_goal') was pushed into the channel.
          break
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
            device_.firmware_validated
          else:
            logger_.error "firmware update failed to validate"

        // We have successfully finished processing all actions.
        // Inform the broker.
        report_status resources

        if device_.max_offline:
          logger_.info "synchronized" --tags={"max-offline": device_.max_offline}
          break
        logger_.info "synchronized"
        broker_.on_idle


      logger_.info "disconnecting" --tags={"device": device_.id}

  handle_nop -> none:
    actions_.send ACTION_NOP_

  /**
  Handles new configurations.

  This function is part of the $EventHandler interface and is called by the
    broker.
  */
  handle_goal new_goal/Map? resources/ResourceManager -> none:
    if not new_goal and not device_.current_state:
      // The new goal indicates that we should use the firmware state.
      // Since there is no current state, we are currently cleanly
      // running the firmware state.
      device_.goal_state = null
      handle_nop
      return

    current_state := device_.current_state or device_.firmware_state
    new_goal = new_goal or device_.firmware_state

    if not new_goal.contains "firmware":
      logger_.error "missing firmware information"
      return

    if current_state["firmware"] != new_goal["firmware"]:
      device_.goal_state = new_goal

      from := current_state["firmware"]
      to := new_goal["firmware"]
      // The firmware changed. We need to update the firmware.
      logger_.info "update firmware from $from to $to"

      // We don't want to update the firmware while we're still
      // processing other actions. So we push the firmware update
      // action into the channel and return.
      actions_.send (action_firmware_update_ resources new_goal["firmware"])
      // If the firmware changed, we don't look at the rest of the
      // goal state. The only thing we care about is the firmware.
      return

    if device_.firmware_state["firmware"] != new_goal["firmware"]:
      assert: current_state["firmware"] == new_goal["firmware"]
      // The firmware has been downloaded and installed, but we haven't
      // rebooted yet.
      // We ignore all other entries in the goal state.
      device_.goal_state = new_goal
      handle_nop
      return

    modification/Modification? := Modification.compute --from=current_state --to=new_goal
    if not modification:
      device_.goal_state = null
      handle_nop
      return

    device_.goal_state = new_goal
    report_status resources

    logger_.info "goal state changed: $(Modification.stringify modification)"

    bundle := []
    modification.on_map "apps"
        --added=: | name/string description |
          if description is not Map:
            logger_.error "invalid description for app $name"
            continue.on_map
          description_map := description as Map
          id := description_map.get Application.KEY_ID
          if not id:
            logger_.error "missing id for container $name"
          else:
            // An app just appeared in the configuration.
            bundle.add (action_app_install_ name id description_map)
        --removed=: | name/string old_description |
          // An app disappeared completely from the configuration. We
          // uninstall it.
          if old_description is not Map:
            continue.on_map
          old_description_map := old_description as Map
          id := old_description_map.get Application.KEY_ID
          if id:
            bundle.add (action_app_uninstall_ name id)
        --modified=: | name/string nested/Modification |
          full_entry := new_goal["apps"][name]
          handle_application_update_ bundle name full_entry nested

    modification.on_value "max-offline"
        --added   =: bundle.add (action_set_max_offline_ it)
        --removed =: bundle.add (action_set_max_offline_ null)
        --updated =: | _ to | bundle.add (action_set_max_offline_ to)

    actions_.send (commit new_goal bundle)

  handle_firmware_update_ resources/ResourceManager new/string -> none:
    actions_.send (action_firmware_update_ resources new)

  handle_application_update_ -> none
      bundle/List
      name/string
      full_entry/Map
      modification/Modification:
    modification.on_value "id"
        --added=: | value |
          logger_.error "current state was missing an id for container $name"
          // Treat it as a request to install the app.
          bundle.add (action_app_install_ name value full_entry)
          return
        --removed=: | value |
          logger_.error "container $name without id"
          // Treat it as a request to uninstall the app.
          bundle.add (action_app_uninstall_ name value)
          return
        --updated=: | from to |
          // An applications had its id (the code) updated. We uninstall
          // the old version and install the new one.
          // TODO(florian): it would be nicer to fetch the new version
          // before uninstalling the old one.
          bundle.add (action_app_uninstall_ name from)
          bundle.add (action_app_install_ name to full_entry)
          return

    bundle.add (action_app_update_ name full_entry)

  action_app_install_ name/string id/string description/Map -> Lambda:
    return::
      // Installing an application doesn't really do much, unless
      // the application is complete.
      // As such we don't update the current state yet, but
      // wait for the completion.
      applications_.install (Application name id --description=description)

  action_app_uninstall_ name/string id/string -> Lambda:
    return::
      application/Application? := applications_.get id
      if application:
        applications_.uninstall application
      else:
        logger_.error "application $name ($id) not found"
      // TODO(florian): the 'uninstall' above only enqueues the installation.
      // We need to wait for its completion.
      device_.state_app_uninstall name id

  action_app_update_ name/string description/Map -> Lambda:
    return::
      id := description.get Application.KEY_ID
      if not id:
        logger_.error "missing id for container $name"
      else:
        old_application/Application? := applications_.get id
        if old_application:
          updated_application := old_application.with --description=description
          applications_.update updated_application
          device_.state_app_install_or_update name description
        else:
          logger_.error "application $name ($id) not found"

  action_app_fetch_ resources/ResourceManager -> Lambda:
    return::
      incomplete/Application? ::= applications_.first_incomplete
      if incomplete:
        resources.fetch_image incomplete.id --organization_id=device_.organization_id:
          | reader/SizedReader |
            applications_.complete incomplete reader
            // The application was successfully installed. Update the current state:
            device_.state_app_install_or_update incomplete.name incomplete.description

  action_set_max_offline_ value/any -> Lambda:
    return:: device_.state_set_max_offline ((value is int) ? Duration --s=value : null)

  action_firmware_update_ resources/ResourceManager new/string -> Lambda:
    return::
      // TODO(kasper): Introduce run-levels for jobs and make sure we're
      // not running a lot of other stuff while we update the firmware.
      old := device_.firmware
      firmware_update logger_ resources
          --organization_id=device_.organization_id
          --old=old
          --new=new
      device_.state_firmware_update new
      report_status resources
      firmware.upgrade

  /**
  Sends the current device status to the broker.

  This includes the firmware state, the current state and the goal state.
  */
  report_status resources/ResourceManager -> none:
    // TODO(florian): we should not send modifications all the time.
    // 1. if nothing changed, no need to send anything.
    // 2. if we got a new goal-state, we can delay reporting the status
    //    for a bit, to give the goal-state time to become the current
    //    state.
    state := {
      "firmware-state": device_.firmware_state,
    }
    if device_.pending_firmware:
      state["pending-firmware"] = device_.pending_firmware
    if device_.current_state:
      state["current-state"] = device_.current_state
    if device_.goal_state:
      state["goal-state"] = device_.goal_state
    resources.report_state device_.id state
