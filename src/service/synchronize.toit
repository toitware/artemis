// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import reader show Reader
import uuid

import system.containers
import system.firmware

import .brokers.broker
import .containers
import .device
import .firmware_update
import .jobs
import .check_in

import ..shared.json_diff show Modification json_equals

firmware_is_validation_pending/bool := firmware.is_validation_pending

class SynchronizeJob extends TaskJob:
  /** Not connected to the network yet. */
  static STATE_DISCONNECTED ::= 0
  /** Connecting to the network. */
  static STATE_CONNECTING ::= 1
  /** Connected to network, but haven't spoken to broker yet. */
  static STATE_CONNECTED_TO_NETWORK ::= 2
  /** Connected, waiting for any goal state updates from broker. */
  static STATE_CONNECTED_TO_BROKER ::= 3
  /** Processing a received goal state update. */
  static STATE_PROCESSING_GOAL ::= 4
  /** Processing a container image update. */
  static STATE_PROCESSING_CONTAINER_IMAGE ::= 5
  /** Processing a firmware update. */
  static STATE_PROCESSING_FIRMWARE ::= 6
  /** Current state is updated to goal state. */
  static STATE_SYNCHRONIZED ::= 7

  static STATE_SUCCESS ::= [
    "disconnected",
    "connecting",
    "connected to network",
    "connected to broker",
    "updating",
    "downloading image",
    "firmware update initiated",
    "synchronized",
  ]
  static STATE_FAILURE ::= [
    null,
    "connecting failed",
    "connection to network lost",
    "connection to broker lost",
    "updating failed",
    "downloading image failed",
    "firmware update failed",
    null,
  ]

  // We allow each step in the synchronization process to
  // only take a specified amount of time. If it takes
  // more time than that we run the risk of waiting for
  // reading from a network connection that is never going
  // to produce more bits.
  static SYNCHRONIZE_STEP_TIMEOUT ::= Duration --m=3

  // We use a minimum offline setting to avoid scheduling the
  // synchronization job too often.
  static OFFLINE_MINIMUM ::= Duration --s=12

  // We allow the synchronization job to start a bit early at
  // random to avoid pathological cases where lots of devices
  // synchronize at the same time over and over again.
  static SCHEDULE_JITTER_MS ::= 8_000

  logger_/log.Logger
  device_/Device
  containers_/ContainerManager
  broker_/BrokerService
  state_/int := STATE_DISCONNECTED

  constructor logger/log.Logger .device_ .containers_ .broker_:
    logger_ = logger.with_name "synchronize"
    super "synchronize"

  schedule now/JobTime last/JobTime? -> JobTime?:
    if not last or firmware_is_validation_pending: return now
    max_offline := device_.max_offline
    if not max_offline: return last + OFFLINE_MINIMUM
    // Compute the duration of the current offline period by
    // letting it run to whatever comes first of the scheduled
    // check-in or hitting the max-offline ceiling, but make
    // sure to not go below the minimum offline setting.
    offline := min (last.to (check_in_schedule now)) max_offline
    return last + (max offline OFFLINE_MINIMUM)

  schedule_tune last/JobTime -> JobTime:
    // Allow the synchronization job to start early, thus pulling
    // the effective minimum offline period down towards zero. As
    // long as the jitter duration is larger than OFFLINE_MINIMUM
    // we still have a lower bound on the effective offline period.
    assert: SCHEDULE_JITTER_MS < OFFLINE_MINIMUM.in_ms
    jitter := Duration --ms=(random SCHEDULE_JITTER_MS)
    // Use the current time rather than the last time we started,
    // so the period begins when we disconnected, not when we
    // started connecting.
    return JobTime.now - jitter

  parse_uuid_ value/string -> uuid.Uuid?:
    catch: return uuid.parse value
    logger_.warn "unable to parse uuid '$value'"
    return null

  run -> none:
    network/net.Client? := null
    try:
      state_ = STATE_DISCONNECTED
      transition_to_ STATE_CONNECTING
      network = net.open
      transition_to_ STATE_CONNECTED_TO_NETWORK
      run_ network
    finally: | is_exception exception |
      transition_to_disconnected_ --error=(is_exception ? exception.value : null)
      if network: network.close
      // TODO(kasper): Only swallow certain exceptions, so we get a
      // proper stack trace for the others.
      return

  run_ network/net.Client -> none:
    // TODO(kasper): It would be ideal if we could wrap the call to
    // connect and provide a timeout. It is hard to do with the current
    // structure where it takes a block. When talking to Supabase the
    // connect call actually doesn't do any waiting so the problem
    // is not really present there.
    broker_.connect --network=network --device=device_: | resources/ResourceManager |
      with_timeout SYNCHRONIZE_STEP_TIMEOUT:
        report_state resources
      while true:
        with_timeout SYNCHRONIZE_STEP_TIMEOUT:
          run_step_ resources
          if state_ != STATE_SYNCHRONIZED: continue
          if device_.max_offline: break
          transition_to_ STATE_CONNECTED_TO_BROKER

  run_step_ resources/ResourceManager -> none:
    if containers_.any_incomplete:
      // TODO(kasper): Change the interface so we don't have to catch
      // exceptions here.
      catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        goal := broker_.fetch_goal --no-wait
        transition_to_connected_
        process_goal_ goal resources
    else:
      with_timeout check_in_timeout:
        goal := broker_.fetch_goal --wait
        transition_to_connected_
        process_goal_ goal resources

    // We only handle incomplete containers when we're done handling
    // the other updates. This means that we prioritize firmware updates
    // and configuration changes over fetching container images.
    if containers_.any_incomplete:
      // TODO(kasper): This is problematic if we're not actually
      // connected yet. Hmm.
      process_first_incomplete_container_image_ resources
      return

    // We have successfully finished processing the new goal state.
    // Inform the broker.
    report_state resources
    transition_to_ STATE_SYNCHRONIZED

  transition_to_ state/int -> none:
    previous := state_
    state_ = state

    // We prefer to avoid polluting the logs when we're just
    // going back to a previous state. This way, we will show
    // how far we got in the synchronization process without
    // flipping too often between the synchronized and
    // connected to broker state.
    if state > previous:
      tags/Map? := null
      if state == STATE_SYNCHRONIZED:
        max_offline := device_.max_offline
        if max_offline: tags = {"max-offline": max_offline}
      logger_.info STATE_SUCCESS[state] --tags=tags

    // If we've successfully connected to the broker, we consider
    // the current firmware functional. Go ahead and validate the
    // firmware if requested to do so.
    if firmware_is_validation_pending and state >= STATE_CONNECTED_TO_BROKER:
      if firmware.validate:
        logger_.info "firmware update validated after connecting to broker"
        firmware_is_validation_pending = false
        device_.firmware_validated
      else:
        logger_.error "firmware update failed to validate"

  transition_to_connected_ -> none:
    if state_ >= STATE_CONNECTED_TO_BROKER: return
    transition_to_ STATE_CONNECTED_TO_BROKER

  transition_to_disconnected_ --error/Object? -> none:
    previous := state_
    state_ = STATE_DISCONNECTED
    if error: logger_.warn STATE_FAILURE[previous] --tags={"error": error}
    logger_.info STATE_SUCCESS[STATE_DISCONNECTED]

    // TODO(kasper): It is a bit too harsh to not give the network
    // another chance to connect, but for now we just reject the
    // updates if the first attempt to connect to the broker fails.
    if firmware_is_validation_pending and previous > STATE_DISCONNECTED:
      logger_.error "firmware update was rejected after failing to connect or validate"
      firmware.rollback

  /**
  Process new goal.
  */
  process_goal_ new_goal/Map? resources/ResourceManager -> none:
    assert: state_ >= STATE_CONNECTED_TO_BROKER
    if not (new_goal or device_.is_current_state_modified):
      // The new goal indicates that we should use the firmware state.
      // Since there is no current state, we are currently cleanly
      // running the firmware state.
      device_.goal_state = null
      return

    current_state := device_.current_state
    new_goal = new_goal or device_.firmware_state

    firmware_to := new_goal.get "firmware"
    if not firmware_to:
      transition_to_ STATE_PROCESSING_GOAL
      throw "missing firmware in goal"

    // We prioritize the firmware updating and deliberately avoid even
    // looking at the other parts of the updated goal state, because we
    // may not understand it before we've completed the firmware update.
    firmware_from := current_state["firmware"]
    if firmware_from != firmware_to:
      device_.goal_state = new_goal
      transition_to_ STATE_PROCESSING_FIRMWARE
      logger_.info "firmware update" --tags={"from": firmware_from, "to": firmware_to}
      handle_firmware_update_ resources firmware_to
      // Handling the firmware update either completes and restarts
      // or throws an exception. We shouldn't get here.
      unreachable

    if device_.firmware_state["firmware"] != firmware_to:
      assert: firmware_from == firmware_to
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

    transition_to_ STATE_PROCESSING_GOAL
    logger_.info "updating" --tags={"changes": Modification.stringify modification}

    modification.on_map "apps"
        --added=: | name/string description |
          if description is not Map:
            logger_.error "updating: container $name has invalid description"
            continue.on_map
          description_map := description as Map
          description_map.get ContainerJob.KEY_ID
              --if_absent=:
                logger_.error "updating: container $name has no id"
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
          logger_.error "updating: container $name gained an id ($value)"
          // Treat it as a request to install the container.
          id := parse_uuid_ value
          if id: handle_container_install_ name id description
          return
        --removed=: | value |
          logger_.error "updating: container $name lost its id ($value)"
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
      logger_.error "updating: container $name not found"
    device_.state_container_uninstall name

  handle_container_update_ name/string description/Map -> none:
    job/ContainerJob? := containers_.get --name=name
    if job:
      containers_.update job description
      device_.state_container_install_or_update name description
    else:
      logger_.error "updating: container $name not found"

  process_first_incomplete_container_image_ resources/ResourceManager -> none:
    assert: state_ >= STATE_CONNECTED_TO_BROKER
    transition_to_ STATE_PROCESSING_CONTAINER_IMAGE
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
    if firmware_is_validation_pending: throw "firmware update: cannot update unvalidated"
    firmware_update logger_ resources --device=device_ --new=new
    try:
      device_.state_firmware_update new
      report_state resources
    finally:
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
    transition_to_connected_
