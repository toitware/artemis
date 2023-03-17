// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor
import reader show Reader
import system.containers
import system.firmware
import uuid

import .containers
import .firmware_update
import .jobs
import .brokers.broker
import .check_in

import .device
import ..shared.json_diff show Modification json_equals

validate_firmware / bool := firmware.is_validation_pending

class SynchronizeJob extends TaskJob implements EventHandler:
  static ACTION_NOP_/Lambda ::= :: null

  logger_/log.Logger
  device_/Device
  containers_/ContainerManager
  broker_/BrokerService

  // We limit the capacity of the actions channel to avoid letting
  // the connect task build up too much work.
  actions_ ::= monitor.Channel 1

  constructor logger/log.Logger .device_ .containers_ .broker_:
    logger_ = logger.with_name "synchronize"
    super "synchronize"

  schedule now/JobTime last/JobTime? -> JobTime?:
    max_offline := device_.max_offline
    if not last or not max_offline: return now
    return min (check_in_schedule now) (last + max_offline)

  commit goal_state/Map actions/List -> Lambda:
    return ::
      actions.do: it.call
      logger_.info "goal state committed"

  parse_uuid_ value/string -> uuid.Uuid?:
    catch: return uuid.parse value
    logger_.warn "unable to parse uuid '$value'"
    return null

  run -> none:
    logger_.info "connecting" --tags={"device": device_.id}
    broker_.connect --device=device_ --callback=this: | resources/ResourceManager |
      logger_.info "connected" --tags={"device": device_.id}

      // TODO(florian): We don't need to report the state every time we
      // connect. We only need to do this the first time we connect or
      // if we know that the broker isn't up to date.
      report_state resources
      broker_.on_idle

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

        // We only handle incomplete containers when we're done processing
        // the other actions. This means that we prioritize firmware updates
        // and configuration changes over fetching containers.
        if containers_.any_incomplete:
          assert: actions_.size == 0  // No issues with getting blocked on send.
          actions_.send (action_container_image_fetch_ resources)
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
        report_state resources

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
    if not (new_goal or device_.is_current_state_modified):
      // The new goal indicates that we should use the firmware state.
      // Since there is no current state, we are currently cleanly
      // running the firmware state.
      device_.goal_state = null
      handle_nop
      return

    current_state := device_.current_state
    new_goal = new_goal or device_.firmware_state

    if not new_goal.contains "firmware":
      logger_.error "missing firmware information"
      // TODO(kasper): Is there a missing action here? That
      // might lead to us not going idle, which is an issue.
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
    report_state resources

    logger_.info "goal state updated" --tags={"changes": Modification.stringify modification}

    bundle := []
    modification.on_map "apps"
        --added=: | name/string description |
          if description is not Map:
            logger_.error "container $name has invalid description"
            continue.on_map
          description_map := description as Map
          description_map.get ContainerJob.KEY_ID
              --if_absent=:
                logger_.error "container $name has no id"
              --if_present=:
                // A container just appeared in the state.
                id := parse_uuid_ it
                if id: bundle.add (action_container_install_ name id description_map)
        --removed=: | name/string |
          // A container disappeared completely from the state. We
          // uninstall it.
          bundle.add (action_container_uninstall_ name)
        --modified=: | name/string nested/Modification |
          description := new_goal["apps"][name]
          handle_container_update_ bundle name description nested

    modification.on_value "max-offline"
        --added   =: bundle.add (action_set_max_offline_ it)
        --removed =: bundle.add (action_set_max_offline_ null)
        --updated =: | _ to | bundle.add (action_set_max_offline_ to)

    actions_.send (commit new_goal bundle)

  handle_firmware_update_ resources/ResourceManager new/string -> none:
    actions_.send (action_firmware_update_ resources new)

  handle_container_update_ -> none
      bundle/List
      name/string
      description/Map
      modification/Modification:
    modification.on_value "id"
        --added=: | value |
          logger_.error "container $name gained an id ($value)"
          // Treat it as a request to install the container.
          id := parse_uuid_ value
          if id: bundle.add (action_container_install_ name id description)
          return
        --removed=: | value |
          logger_.error "container $name lost its id ($value)"
          // Treat it as a request to uninstall the container.
          bundle.add (action_container_uninstall_ name)
          return
        --updated=: | from to |
          // A container had its id (the code) updated. We uninstall
          // the old version and install the new one.
          // TODO(florian): it would be nicer to fetch the new version
          // before uninstalling the old one.
          bundle.add (action_container_uninstall_ name)
          id := parse_uuid_ to
          if id: bundle.add (action_container_install_ name id description)
          return

    bundle.add (action_container_update_ name description)

  action_container_install_ name/string id/uuid.Uuid description/Map -> Lambda:
    return::
      job := containers_.create
          --name=name
          --id=id
          --description=description
      containers_.install job
      // Installing a container job doesn't really do much, unless
      // the job is already complete because we've found its
      // container image in flash. In that case, we must remember
      // to update the device state.
      if job.is_complete:
        device_.state_container_install_or_update name description

  action_container_uninstall_ name/string -> Lambda:
    return::
      job/ContainerJob? := containers_.get --name=name
      if job:
        containers_.uninstall job
      else:
        logger_.error "container $name not found"
      device_.state_container_uninstall name

  action_container_update_ name/string description/Map -> Lambda:
    return::
      job/ContainerJob? := containers_.get --name=name
      if job:
        containers_.update job description
        device_.state_container_install_or_update name description
      else:
        logger_.error "container $name not found"

  action_container_image_fetch_ resources/ResourceManager -> Lambda:
    return::
      incomplete/ContainerJob? ::= containers_.first_incomplete
      if incomplete:
        resources.fetch_image incomplete.id:
          | reader/Reader |
            containers_.complete incomplete reader
            // The container image was successfully installed, so the job is
            // now complete. Go ahead and update the current state!
            device_.state_container_install_or_update
                incomplete.name
                incomplete.description

  action_set_max_offline_ value/any -> Lambda:
    return:: device_.state_set_max_offline ((value is int) ? Duration --s=value : null)

  action_firmware_update_ resources/ResourceManager new/string -> Lambda:
    return::
      // TODO(kasper): Introduce run-levels for jobs and make sure we're
      // not running a lot of other stuff while we update the firmware.
      success := firmware_update logger_ resources --device=device_ --new=new
      if success:
        device_.state_firmware_update new
        report_state resources
        firmware.upgrade

  /**
  Sends the current device state to the broker.

  This includes the firmware state, the current state and the goal state.
  */
  report_state resources/ResourceManager -> none:
    // TODO(florian): we should not send modifications all the time.
    // 1. if nothing changed, no need to send anything.
    // 2. if we got a new goal-state, we can delay reporting the state
    //    for a bit, to give the goal-state time to become the current
    //    state.
    state := {
      "firmware-state": device_.firmware_state,
    }
    if device_.pending_firmware:
      state["pending-firmware"] = device_.pending_firmware
    if device_.is_current_state_modified:
      state["current-state"] = device_.current_state
    if device_.goal_state:
      state["goal-state"] = device_.goal_state
    resources.report_state state
