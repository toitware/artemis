// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
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

class SynchronizeJob extends TaskJob:
  logger_/log.Logger
  device_/Device
  containers_/ContainerManager
  broker_/BrokerService

  constructor logger/log.Logger .device_ .containers_ .broker_:
    logger_ = logger.with_name "synchronize"
    super "synchronize"

  schedule now/JobTime last/JobTime? -> JobTime?:
    max_offline := device_.max_offline
    if not last or not max_offline: return now
    return min (check_in_schedule now) (last + max_offline)

  parse_uuid_ value/string -> uuid.Uuid?:
    catch: return uuid.parse value
    logger_.warn "unable to parse uuid '$value'"
    return null

  run -> none:
    logger_.info "connecting" --tags={"device": device_.id}
    broker_.connect --device=device_: | resources/ResourceManager |
      logger_.info "connected" --tags={"device": device_.id}
      exception := null
      try:
        // TODO(florian): We don't need to report the state every time we
        // connect. We only need to do this the first time we connect or
        // if we know that the broker isn't up to date.
        report_state resources
        while true:
          new_goal/Map? := null
          got_goal/bool := false
          wait := not containers_.any_incomplete
          // TODO(kasper): We should probably only filter out some stack
          // traces here and not everything.
          exception = catch:
            with_timeout check_in_timeout:
              new_goal = broker_.fetch_goal --wait=wait
              got_goal = true

          if got_goal:
            handle_goal_ new_goal resources
          else if wait:
            // Timed out waiting or got an error communicating
            // with the cloud. Get out and retry later.
            break

          // We only handle incomplete containers when we're done handling
          // the other updates. This means that we prioritize firmware updates
          // and configuration changes over fetching container images.
          if containers_.any_incomplete:
            handle_fetch_container_image_ resources
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
      finally:
        if exception:
          logger_.warn "disconnected" --tags={"device": device_.id, "error": exception}
        else:
          logger_.info "disconnected" --tags={"device": device_.id}

  /**
  Handles new configurations.
  */
  handle_goal_ new_goal/Map? resources/ResourceManager -> none:
    if not (new_goal or device_.is_current_state_modified):
      // The new goal indicates that we should use the firmware state.
      // Since there is no current state, we are currently cleanly
      // running the firmware state.
      device_.goal_state = null
      return

    current_state := device_.current_state
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

      // We prioritize the firmware updating and deliberately
      // avoid looking at the updated goal state, because we
      // may not understand it before we've completed the
      // firmware update.
      handle_firmware_update_ resources new_goal["firmware"]
      // TODO(kasper): Here the firmware update failed, so we
      // probably need to deal with the failure instead of just
      // going into a loop where we continue to ask for the
      // new goal state.
      return

    if device_.firmware_state["firmware"] != new_goal["firmware"]:
      assert: current_state["firmware"] == new_goal["firmware"]
      // The firmware has been downloaded and installed, but we haven't
      // rebooted yet.
      // We ignore all other entries in the goal state.
      device_.goal_state = new_goal
      return

    modification/Modification? := Modification.compute --from=current_state --to=new_goal
    if not modification:
      device_.goal_state = null
      return

    device_.goal_state = new_goal
    report_state resources

    logger_.info "goal state updated" --tags={"changes": Modification.stringify modification}

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
                if id: handle_container_install_ name id description_map
        --removed=: | name/string |
          // A container disappeared completely from the state. We
          // uninstall it.
          handle_container_uninstall_ name
        --modified=: | name/string nested/Modification |
          description := new_goal["apps"][name]
          handle_container_modification_ name description nested

    modification.on_value "max-offline"
        --added   =: handle_set_max_offline_ it
        --removed =: handle_set_max_offline_ null
        --updated =: | _ to | handle_set_max_offline_ to

  handle_container_modification_ -> none
      name/string
      description/Map
      modification/Modification:
    modification.on_value "id"
        --added=: | value |
          logger_.error "container $name gained an id ($value)"
          // Treat it as a request to install the container.
          id := parse_uuid_ value
          if id: handle_container_install_ name id description
          return
        --removed=: | value |
          logger_.error "container $name lost its id ($value)"
          // Treat it as a request to uninstall the container.
          handle_container_uninstall_ name
          return
        --updated=: | from to |
          // A container had its id (the code) updated. We uninstall
          // the old version and install the new one.
          // TODO(florian): it would be nicer to fetch the new version
          // before uninstalling the old one.
          handle_container_uninstall_ name
          id := parse_uuid_ to
          if id: handle_container_install_ name id description
          return

    handle_container_update_ name description

  handle_container_install_ name/string id/uuid.Uuid description/Map -> none:
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

  handle_container_uninstall_ name/string -> none:
    job/ContainerJob? := containers_.get --name=name
    if job:
      containers_.uninstall job
    else:
      logger_.error "container $name not found"
    device_.state_container_uninstall name

  handle_container_update_ name/string description/Map -> none:
    job/ContainerJob? := containers_.get --name=name
    if job:
      containers_.update job description
      device_.state_container_install_or_update name description
    else:
      logger_.error "container $name not found"

  handle_fetch_container_image_ resources/ResourceManager -> none:
    incomplete/ContainerJob? ::= containers_.first_incomplete
    if not incomplete: return
    resources.fetch_image incomplete.id: | reader/Reader |
      containers_.complete incomplete reader
      // The container image was successfully installed, so the job is
      // now complete. Go ahead and update the current state!
      device_.state_container_install_or_update
          incomplete.name
          incomplete.description

  handle_set_max_offline_ value/any -> none:
    device_.state_set_max_offline ((value is int) ? Duration --s=value : null)

  // TODO(kasper): Introduce run-levels for jobs and make sure we're
  // not running a lot of other stuff while we update the firmware.
  handle_firmware_update_ resources/ResourceManager new/string -> none:
    // TODO(kasper): If we end up getting a new goal state before
    // validating the previous firmware update, we will be doing
    // this with update from an unvalidated firmware. We need to
    // make sure that writing a new firmware auto-validates or
    // move the validation check a bit earlier, so we do it before
    // starting to update.
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
