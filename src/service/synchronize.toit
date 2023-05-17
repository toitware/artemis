// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import reader show Reader
import uuid

import crypto.sha256
import encoding.tison

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
    "image download initiated",
    "firmware update initiated",
    "synchronized",
  ]
  static STATE_FAILURE ::= [
    null,
    "connecting failed",
    "connection to network lost",
    "connection to broker lost",
    "updating failed",
    "image download failed",
    "firmware update failed",
    null,
  ]

  // The status is used to dermine the frequency and runlevel
  // of the synchronizations. We determine the current
  // synchronization status by comparing the ideal time between
  // synchronizations (as dictated by the max-offline setting)
  // with the actual time since the last successful attempt.
  // If we have been unsuccessful in synchronizing for too long,
  // we push the status into yellow, orange, and eventually red.
  static STATUS_GREEN  ::= 100
  static STATUS_YELLOW ::= 101
  static STATUS_ORANGE ::= 102
  static STATUS_RED    ::= 103
  static STATUS_CHANGES_AFTER_ATTEMPTS ::= 4  // TODO(kasper): This is low for testing.

  // The status limit unit controls how we round when
  // we compute the number of missed synchronization
  // attempts. As an example, let's assume that we've
  // decided to change the status after 8 attempts and
  // that the unit is 1h. If max-offline is 1h or less,
  // we will change the status after 8h. If max-offline
  // is 12h, we will change the status after 96h.
  static STATUS_LIMIT_UNIT_US ::= Duration.MICROSECONDS_PER_MINUTE  // TODO(kasper): This is low for testing.
  status_limit_us_/int := ?

  // We only allow the device to stay running for a
  // specified amount of time when non-green. This
  // is intended to let the device recover through
  // resetting memory and (some) peripheral state.
  static STATUS_NON_GREEN_MAX_UPTIME ::= Duration --m=10

  // We allow each step in the synchronization process to
  // only take a specified amount of time. If it takes
  // more time than that we run the risk of waiting for
  // reading from a network connection that is never going
  // to produce more bits.
  static SYNCHRONIZE_STEP_TIMEOUT ::= Duration --m=3

  // We try to connect to networks in a loop, so to avoid
  // spending too much time trying to connect we have a
  // timeout that governs the total time spent in the loop.
  static CONNECT_TO_BROKER_TIMEOUT ::= Duration --m=1

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

  // We maintain a list of pending steps that we use to break
  // complex updates into smaller steps. It would be ideal to
  // make this more local and perhaps get it returned from
  // process goal.
  pending_steps_/Deque ::= Deque

  // The synchronization job can be controlled from the outside
  // and it supports requesting to go online or offline. Since
  // multiple clients can request both at the same time, we keep
  // track of the level, e.g. the outstanding number of requests.
  control_level_online_/int := 0
  control_level_offline_/int := 0

  constructor logger/log.Logger .device_ .containers_ .broker_:
    logger_ = logger.with_name "synchronize"
    max_offline := device_.max_offline
    status_limit_us_ = compute_status_limit_us_ max_offline
    super "synchronize"

  control --online/bool --close/bool=false -> none:
    if close:
      if online:
        // If we're no longer force to stay online, we let the
        // synchronization job stop after the next successful
        // synchronization. This is a somewhat conservative and
        // we could be more aggressive in shutting down the
        // job if we're just waiting for a new state.
        control_level_online_--
      else:
        // If we're no longer forced to stay offline, we may be
        // able to run the synchronization job now.
        if control_level_offline_-- == 1: scheduler_.on_job_updated
    else:
      if online:
        // If we're forced to go online, we let the scheduler
        // know that we may be able to run the synchronization job.
        if control_level_online_++ == 0: scheduler_.on_job_updated
        // TODO(kasper): We should really wait until we have had the
        // chance to consider going online. There is a risk that we
        // get so little time that we don't even try and that seems
        // hard to reason about.
      else:
        // If we're forced to go offline, we stop the synchronization
        // job right away. This is somewhat abrupt, but if users
        // need to control the network, we do not want to return
        // from this method without having shut it down.
        if control_level_offline_++ == 0: stop

  runlevel -> int:
    return Job.RUNLEVEL_SAFE

  schedule now/JobTime last/JobTime? -> JobTime?:
    if firmware_is_validation_pending or not last: return now
    if control_level_offline_ > 0: return null
    if control_level_online_ > 0: return now
    max_offline := device_.max_offline
    schedule/JobTime := ?
    if max_offline:
      // Allow the device to connect more often if we're having
      // trouble synchronzing. This is particularly welcome on
      // devices with a high max-offline setting (multiple hours).
      status := determine_status_
      if status > STATUS_YELLOW:
        max_offline /= (status == STATUS_RED) ? 4 : 2
      // Compute the duration of the current offline period by
      // letting it run to whatever comes first of the scheduled
      // check-in or hitting the max-offline ceiling, but make
      // sure to not go below the minimum offline setting.
      offline := min (last.to (check_in_schedule now)) max_offline
      schedule = last + (max offline OFFLINE_MINIMUM)
    else:
      schedule = last + OFFLINE_MINIMUM
    if now < schedule:
      // If we're not going to schedule the synchronization
      // job now, we allow running all other jobs.
      scheduler_.transition --runlevel=Job.RUNLEVEL_NORMAL
    return schedule

  schedule_tune last/JobTime -> JobTime:
    // If we got abruptly stopped by a request to go offline, we
    // treat it as if we didn't get a chance to run in the first
    // place. This makes us eager to re-try once we're allowed
    // to go online again.
    if control_level_offline_ > 0: return last
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
    status := determine_status_
    runlevel := Job.RUNLEVEL_NORMAL
    if firmware_is_validation_pending:
      runlevel = Job.RUNLEVEL_SAFE
    else if status > STATUS_GREEN:
      uptime := Duration --us=Time.monotonic_us
      if uptime >= STATUS_NON_GREEN_MAX_UPTIME:
        // If we're experiencing problems connecting, the most
        // unjarring thing we can do is to force occassional
        // reboots of the system. Rebooting the system will reset
        // the uptime, so we end up only periodically rebooting.
        // This is in almost all ways better than disallowing
        // some or most containers from running, so this is our
        // starting point for all non-green statuses.
        runlevel = Job.RUNLEVEL_STOP
      else if status > STATUS_YELLOW:
        assert: status == STATUS_ORANGE or status == STATUS_RED
        runlevel = Job.RUNLEVEL_CRITICAL
        // If we're really, really having trouble synchronizing
        // we let the synchronizer run in safe mode every now
        // and then. It is our get-out-of-jail option, but we
        // really prefer running containers marked critical.
        if status == STATUS_RED and (random 100) < 15:
          runlevel = Job.RUNLEVEL_SAFE
    scheduler_.transition --runlevel=runlevel
    assert: runlevel != Job.RUNLEVEL_STOP  // Stop does not return.

    try:
      start := Time.monotonic_us
      limit := start + CONNECT_TO_BROKER_TIMEOUT.in_us
      while not connect_network_ and Time.monotonic_us < limit:
        // If we didn't manage to connect to the broker, we
        // try to connect again. The next time, due to the
        // quarantining, we might pick a different network.
        logger_.info "connecting to broker failed - retrying"
    finally:
      if firmware_is_validation_pending:
        logger_.error "firmware update was rejected after failing to connect or validate"
        firmware.rollback

  /**
  Tries to connect to the network and run the synchronization.

  Returns whether we are done with this connection attempt (true)
    or if another attempt makes sense if time permits (false).
  */
  connect_network_ -> bool:
    network/net.Client? := null
    try:
      state_ = STATE_DISCONNECTED
      transition_to_ STATE_CONNECTING
      // TODO(kasper): Add timeout of net.open.
      network = net.open
      while true:
        transition_to_ STATE_CONNECTED_TO_NETWORK
        done := connect_broker_ network
        // TODO(kasper): Add timeout for check_in.
        check_in network logger_ --device=device_
        if done: return true
    finally: | is_exception exception |
      // We do not expect to be canceled outside of tests, but
      // if we do we prefer maintaining the proper state and
      // get the network correctly quarantined and closed.
      critical_do:
        // We retry if we connected to the network, but failed
        // to actually connect to the broker. This could be an
        // indication that the network doesn't let us connect,
        // so we prefer using a different network for a while.
        done := state_ != STATE_CONNECTED_TO_NETWORK
        transition_to_disconnected_ --error=(is_exception ? exception.value : null)
        if network:
          // If we are planning to retry another network,
          // we quarantine the one we just tried.
          // TODO(kasper): Add timeout for network.quarantine.
          if not done: network.quarantine
          // TODO(kasper): Add timeout for network.close.
          network.close
        // If we're canceled, we should make sure to propagate
        // the canceled exception and not just swallow it.
        // Otherwise, the caller can easily run into a loop
        // where it is repeatedly asked to retry the connect.
        if not Task.current.is_canceled: return done

  /**
  Tries to connect to the broker and step through the
    necessary synchronization.

  Returns whether we are done synchronizing (true) or if we
    need another attempt using the already established network
    connection (false).
  */
  connect_broker_ network/net.Client -> bool:
    // TODO(kasper): Add timeout for connect.
    resources := broker_.connect --network=network --device=device_
    try:
      goal_state/Map? := null
      while true:
        with_timeout SYNCHRONIZE_STEP_TIMEOUT:
          goal_state = synchronize_step_ resources goal_state
          if goal_state: continue
          if control_level_online_ == 0 and device_.max_offline: return true
          now := JobTime.now
          if (check_in_schedule now) <= now: return false
          transition_to_ STATE_CONNECTED_TO_BROKER
      finally:
        // TODO(kasper): Add timeout for close.
        resources.close

  synchronize_step_ resources/ResourceManager goal_state/Map? -> Map?:
    // If our state has changed, we communicate it to the cloud.
    report_state_if_changed resources --goal_state=goal_state

    if goal_state:
      // If we already have a goal state, it means that we're going
      // through the steps to get the current state updated to
      // match the goal state. We still allow the broker to give us
      // a new updated goal state in the middle of this, so we check
      // for that here.
      goal_state_updated := false
      // TODO(kasper): Change the interface so we don't have to
      // catch exceptions to figure out if we got a new goal state.
      catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        goal_state = resources.fetch_goal --no-wait
        goal_state_updated = true
        transition_to_connected_
      if goal_state_updated:
        process_goal_ goal_state resources
      else:
        // We always have a pending step here, because the goal state
        // is non-null for the step and that only happens when we have
        // pending steps.
        pending/Lambda := pending_steps_.remove_first
        pending.call resources
    else:
      goal_state = resources.fetch_goal --wait
      transition_to_connected_
      process_goal_ goal_state resources

    // We only handle pending steps when we're done handling the other
    // updates. This means that we prioritize firmware updates and
    // state changes over dealing with any pending steps.
    if pending_steps_.size > 0: return goal_state

    // We have successfully finished processing the new goal state
    // and any pending steps. Inform the broker.
    transition_to_ STATE_CONNECTED_TO_BROKER
    report_state_if_changed resources
    transition_to_ STATE_SYNCHRONIZED
    return null

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
        if max_offline and control_level_online_ == 0:
          tags = {"max-offline": max_offline}
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

    // Keep track of the last time we succesfully synchronized.
    if state == STATE_SYNCHRONIZED:
      device_.synchronized_last_us_update JobTime.now.us
      scheduler_.transition --runlevel=Job.RUNLEVEL_NORMAL

  transition_to_connected_ -> none:
    if state_ >= STATE_CONNECTED_TO_BROKER: return
    transition_to_ STATE_CONNECTED_TO_BROKER

  transition_to_disconnected_ --error/Object? -> none:
    previous := state_
    state_ = STATE_DISCONNECTED
    if error: logger_.warn STATE_FAILURE[previous] --tags={"error": error}
    logger_.info STATE_SUCCESS[STATE_DISCONNECTED]

  determine_status_ -> int:
    last := device_.synchronized_last_us
    elapsed := JobTime.now.us
    if last: elapsed -= last
    limit := status_limit_us_
    if elapsed < limit:
      return STATUS_GREEN
    else if elapsed < (limit * 2):
      return STATUS_YELLOW
    else if elapsed < (limit * 3):
      return STATUS_ORANGE
    else:
      return STATUS_RED

  static compute_status_limit_us_ max_offline/Duration? -> int:
    // Compute the number of time units that correspond to
    // the max-offline setting by using ceiling division.
    max_offline_units := max_offline
        ? 1 + (max_offline.in_us - 1) / STATUS_LIMIT_UNIT_US
        : 1
    // Convert the units back to a number of microseconds and
    // derive the limit from that and the number of attempts
    // between status changes.
    max_offline_us := max_offline_units * STATUS_LIMIT_UNIT_US
    return max_offline_us * STATUS_CHANGES_AFTER_ATTEMPTS

  /**
  Process new goal.
  */
  process_goal_ new_goal_state/Map? resources/ResourceManager -> none:
    assert: state_ >= STATE_CONNECTED_TO_BROKER
    pending_steps_.clear

    if not (new_goal_state or device_.is_current_state_modified):
      // The new goal indicates that we should use the firmware state.
      // Since there is no current state, we are currently cleanly
      // running the firmware state.
      return

    current_state := device_.current_state
    new_goal_state = new_goal_state or device_.firmware_state

    firmware_to := new_goal_state.get "firmware"
    if not firmware_to:
      transition_to_ STATE_PROCESSING_GOAL
      throw "missing firmware in goal"

    // We prioritize the firmware updating and deliberately avoid even
    // looking at the other parts of the updated goal state, because we
    // may not understand it before we've completed the firmware update.
    firmware_from := current_state["firmware"]
    if firmware_from != firmware_to:
      transition_to_ STATE_PROCESSING_FIRMWARE
      logger_.info "firmware update" --tags={"from": firmware_from, "to": firmware_to}
      report_state_if_changed resources --goal_state=new_goal_state
      handle_firmware_update_ resources firmware_to
      // Handling the firmware update either completes and restarts
      // or throws an exception. We shouldn't get here.
      unreachable

    if device_.firmware_state["firmware"] != firmware_to:
      assert: firmware_from == firmware_to
      // The firmware has been downloaded and installed, but we haven't
      // rebooted yet. We ignore all other entries in the new goal state.
      return

    modification/Modification? := Modification.compute
        --from=current_state
        --to=new_goal_state
    if not modification:
      // No changes. All good.
      return

    transition_to_ STATE_PROCESSING_GOAL
    logger_.info "updating" --tags={"changes": Modification.stringify modification}
    report_state_if_changed resources --goal_state=new_goal_state

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
          description := new_goal_state["apps"][name]
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
    if job := containers_.create --name=name --id=id --description=description:
      device_.state_container_install_or_update name description
      containers_.install job
      return

    pending_steps_.add:: | resources/ResourceManager |
      assert: state_ >= STATE_CONNECTED_TO_BROKER
      transition_to_ STATE_PROCESSING_CONTAINER_IMAGE
      resources.fetch_image id: | reader/Reader |
        job := containers_.create
            --name=name
            --id=id
            --description=description
            --reader=reader
        device_.state_container_install_or_update name description
        containers_.install job

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

  handle_set_max_offline_ value/any -> none:
    max_offline := (value is int) ? Duration --s=value : null
    device_.state_set_max_offline max_offline
    status_limit_us_ = compute_status_limit_us_ max_offline

  handle_firmware_update_ resources/ResourceManager new/string -> none:
    if firmware_is_validation_pending: throw "firmware update: cannot update unvalidated"
    runlevel := scheduler_.runlevel
    updated := false
    try:
      // TODO(kasper): We should make sure we're not increasing the
      // runlevel here. For now, that cannot happen because we're
      // using safe mode for firmware updates, but if we were to
      // change this, we shouldn't increase the runlevel here.
      scheduler_.transition --runlevel=Job.RUNLEVEL_SAFE
      firmware_update logger_ resources --device=device_ --new=new
      updated = true
      transition_to_ STATE_CONNECTED_TO_BROKER
      device_.state_firmware_update new
      report_state_if_changed resources
    finally:
      if updated: firmware.upgrade
      scheduler_.transition --runlevel=runlevel

  /**
  Reports the current device state to the broker, but only if we know
    it may have changed.

  The reported state includes the firmware state, the current state,
    and the goal state.
  */
  report_state_if_changed resources/ResourceManager --goal_state/Map?=null -> none:
    state := {
      "firmware-state": device_.firmware_state,
    }
    if device_.pending_firmware:
      state["pending-firmware"] = device_.pending_firmware
    if device_.is_current_state_modified:
      state["current-state"] = device_.current_state
    if goal_state:
      state["goal-state"] = goal_state

    sha := sha256.Sha256
    sha.add (tison.encode state)
    checksum := sha.get
    if checksum == device_.report_state_checksum: return

    resources.report_state state
    transition_to_connected_
    device_.report_state_checksum = checksum
    logger_.info "synchronized state to broker"
