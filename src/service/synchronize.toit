// Copyright (C) 2022 Toitware ApS. All rights reserved.

import io
import log
import net
import uuid

import crypto.sha256
import encoding.tison

import system.containers
import system.firmware
import watchdog show Watchdog WatchdogServiceClient

import .brokers.broker
import .check-in
import .containers
import .device
import .firmware-update
import .jobs
import .ntp
import .storage

import ..shared.json-diff show Modification json-equals

/**
A class representing the new goal state to achieve.
Also contains the pending steps to reach the goal state.
*/
class Goal:
  goal-state/Map
  pending-steps_/Deque? := null

  constructor .goal-state:

  has-pending-steps -> bool:
    return pending-steps_ != null

  remove-first-pending-step -> Lambda:
    result := pending-steps_.remove-first
    if pending-steps_.is-empty:
      pending-steps_ = null
    return result

  add-pending-step step/Lambda -> none:
    if pending-steps_ == null:
      pending-steps_ = Deque
    pending-steps_.add step

class SynchronizeJob extends TaskJob:
  static NAME ::= "synchronize"

  /** Not connected to the network yet. */
  static STATE-DISCONNECTED ::= 0
  /** Connecting to the network. */
  static STATE-CONNECTING ::= 1
  /** Connected to network, but haven't spoken to broker yet. */
  static STATE-CONNECTED-TO-NETWORK ::= 2
  /** Connected, waiting for any goal state updates from broker. */
  static STATE-CONNECTED-TO-BROKER ::= 3
  /** Processing a received goal state update. */
  static STATE-PROCESSING-GOAL ::= 4
  /** Processing a container image update. */
  static STATE-PROCESSING-CONTAINER-IMAGE ::= 5
  /** Processing a firmware update. */
  static STATE-PROCESSING-FIRMWARE ::= 6
  /** Current state is updated to goal state. */
  static STATE-SYNCHRONIZED ::= 7

  static STATE-SUCCESS ::= [
    "disconnected",
    "connecting",
    "connected to network",
    "connected to broker",
    "updating",
    "image download initiated",
    "firmware update initiated",
    "synchronized",
  ]
  static STATE-FAILURE ::= [
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
  static STATUS-GREEN  ::= 100
  static STATUS-YELLOW ::= 101
  static STATUS-ORANGE ::= 102
  static STATUS-RED    ::= 103
  static STATUS-CHANGES-AFTER-ATTEMPTS ::= 8

  // The status limit unit controls how we round when
  // we compute the number of missed synchronization
  // attempts. As an example, let's assume that we've
  // decided to change the status after 8 attempts and
  // that the unit is 1h. If max-offline is 1h or less,
  // we will change the status after 8h. If max-offline
  // is 12h, we will change the status after 96h.
  static STATUS-LIMIT-UNIT-US ::= Duration.MICROSECONDS-PER-HOUR
  status-limit-us_/int := ?

  // We only allow the device to stay running for a
  // specified amount of time when non-green. This
  // is intended to let the device recover through
  // resetting memory and (some) peripheral state.
  static STATUS-NON-GREEN-MAX-UPTIME ::= Duration --m=10

  // We are careful and try to avoid spending too much
  // time waiting for network operations. These can be
  // quite slow in particular for cellular networks, so
  // these settings may have to be tweaked.
  static TIMEOUT-NETWORK-OPEN       ::= Duration --m=5
  static TIMEOUT-NETWORK-QUARANTINE ::= Duration --s=10
  static TIMEOUT-NETWORK-CLOSE      ::= Duration --s=30

  // We try to connect to networks in a loop, so to avoid
  // spending too much time trying to connect we have a
  // timeout that governs the total time spent in the loop.
  static TIMEOUT-BROKER-CONNECT ::= Duration --m=1
  static TIMEOUT-BROKER-CLOSE   ::= Duration --s=30

  // We allow each step in the synchronization process to
  // only take a specified amount of time. If it takes
  // more time than that we run the risk of waiting for
  // reading from a network connection that is never going
  // to produce more bits.
  static TIMEOUT-SYNCHRONIZE-STEP ::= Duration --m=3

  // We require the check-in to be reasonably fast. We don't
  // want to waste too much time waiting for it.
  static TIMEOUT-CHECK-IN ::= Duration --s=20

  // The watchdog creation should always work, but just in
  // case we have a timeout for it.
  static TIMEOUT-WATCHDOG-CREATION-MS ::= 1_000

  // We use a minimum offline setting to avoid scheduling the
  // synchronization job too often.
  static OFFLINE-MINIMUM ::= Duration --s=12

  // We allow the synchronization job to start a bit early at
  // random to avoid pathological cases where lots of devices
  // synchronize at the same time over and over again.
  static SCHEDULE-JITTER-MS ::= 8_000

  /** The RAM key and value for the firmware clean state. */
  static RAM-FIRMWARE-IS-CLEAN-KEY ::= "firmware-is-clean"
  static RAM-FIRMWARE-IS-CLEAN-VALUE ::= 0xc001

  logger_/log.Logger
  device_/Device
  containers_/ContainerManager
  broker_/BrokerService
  ntp_/NtpRequest?
  state_/int := STATE-DISCONNECTED

  is-firmware-validation-pending_/bool := ?
  is-firmware-upgrade-pending_/bool := false

  // The synchronization job can be controlled from the outside
  // and it supports requesting to go online or offline. Since
  // multiple clients can request both at the same time, we keep
  // track of the level, e.g. the outstanding number of requests.
  control-level-online_/int := 0
  control-level-offline_/int := 0

  storage_/Storage
  watchdog-client_/WatchdogServiceClient?
  watchdog_/Watchdog?

  constructor
      logger/log.Logger
      .device_
      .containers_
      .broker_
      saved-state/any
      --storage/Storage
      --ntp/NtpRequest?=null:
    logger_ = logger.with-name NAME
    ntp_ = ntp
    max-offline := device_.max-offline
    status-limit-us_ = compute-status-limit-us_ max-offline

    if (storage.ram-load RAM-FIRMWARE-IS-CLEAN-KEY) == RAM-FIRMWARE-IS-CLEAN-VALUE:
      is-firmware-validation-pending_ = false
    else:
      pending := firmware.is-validation-pending
      is-firmware-validation-pending_ = pending
      if not pending:
        storage.ram-store RAM-FIRMWARE-IS-CLEAN-KEY RAM-FIRMWARE-IS-CLEAN-VALUE

    storage_ = storage
    watchdog-client_ = null
    watchdog_ = null
    catch --trace:
      // Creating the watchdog should never fail, but we also don't want this
      // to be the reason we can't recover from a bad state.
      // If we can't create a watchdog just run the synchronization without
      // any watchdog.
      with-timeout --ms=TIMEOUT-WATCHDOG-CREATION-MS:
        watchdog-client_ = (WatchdogServiceClient).open as WatchdogServiceClient
        // Make sure there is some kind of recovery if the device can't synchronize.
        watchdog_ = watchdog-client_.create "toit.io/artemis/synchronize"
        // Note that we don't stop/close the watchdog when the synchronize-job is done.
        // If we go to deep-sleep then the watchdog timer isn't relevant.
        // If the job is started again, then we will reuse the existing watchdog
        // without feeding it (thus continuing the countdown).
        start-watchdog_ watchdog_ max-offline
    super NAME saved-state

  control --online/bool --close/bool=false -> none:
    if close:
      if online:
        // If we're no longer force to stay online, we let the
        // synchronization job stop after the next successful
        // synchronization. This is a somewhat conservative and
        // we could be more aggressive in shutting down the
        // job if we're just waiting for a new state.
        control-level-online_--
        if control-level-online_ == 0:
          logger_.info "request to run online - stop"
      else:
        // Restart the watchdog.
        // We start the timer from scratch. This means that repeated
        // requests to go offline can prevent the watchdog from triggering.
        start-watchdog_ watchdog_ device_.max-offline

        // If we're no longer forced to stay offline, we may be
        // able to run the synchronization job now.
        control-level-offline_--
        if control-level-online_ == 0:
          logger_.info "request to run offline - stop"
          scheduler_.on-job-updated
    else:
      if online:
        control-level-online_++
        // If we're forced to go online, we let the scheduler
        // know that we may be able to run the synchronization job.
        if control-level-online_ == 1:
          logger_.info "request to run online - start"
          scheduler_.on-job-updated
        // TODO(kasper): We should really wait until we have had the
        // chance to consider going online. There is a risk that we
        // get so little time that we don't even try and that seems
        // hard to reason about.
      else:
        // If we're forced to go offline, we stop the synchronization
        // job right away. This is somewhat abrupt, but if users
        // need to control the network, we do not want to return
        // from this method without having shut it down.
        stop-watchdog_ watchdog_
        control-level-offline_++
        if control-level-offline_ == 1:
          logger_.info "request to run offline - start"
          stop

  runlevel -> int:
    return Job.RUNLEVEL-CRITICAL

  schedule now/JobTime last/JobTime? -> JobTime?:
    if is-firmware-validation-pending_ or not last: return now
    if control-level-offline_ > 0: return null
    if control-level-online_ > 0: return now
    max-offline := device_.max-offline
    schedule/JobTime := ?
    if max-offline:
      // Allow the device to connect more often if we're having
      // trouble synchronzing. This is particularly welcome on
      // devices with a high max-offline setting (multiple hours).
      status := determine-status_
      if status > STATUS-YELLOW:
        max-offline /= (status == STATUS-RED) ? 4 : 2
      schedule = last + (max max-offline OFFLINE-MINIMUM)
    else:
      schedule = last + OFFLINE-MINIMUM
    if now < schedule:
      // If we're not going to schedule the synchronization
      // job now, we allow running all other jobs.
      scheduler_.transition --runlevel=Job.RUNLEVEL-NORMAL
    return schedule

  schedule-tune last/JobTime -> JobTime:
    // If we got abruptly stopped by a request to go offline, we
    // treat it as if we didn't get a chance to run in the first
    // place. This makes us eager to re-try once we're allowed
    // to go online again.
    if control-level-offline_ > 0: return last
    // Allow the synchronization job to start early, thus pulling
    // the effective minimum offline period down towards zero. As
    // long as the jitter duration is larger than OFFLINE_MINIMUM
    // we still have a lower bound on the effective offline period.
    assert: SCHEDULE-JITTER-MS < OFFLINE-MINIMUM.in-ms
    jitter := Duration --ms=(random SCHEDULE-JITTER-MS)
    // Use the current time rather than the last time we started,
    // so the period begins when we disconnected, not when we
    // started connecting.
    return JobTime.now - jitter

  parse-uuid_ value/string -> uuid.Uuid?:
    catch: return uuid.parse value
    logger_.warn "unable to parse uuid '$value'"
    return null

  run -> none:
    status := determine-status_
    runlevel := Job.RUNLEVEL-NORMAL
    if is-firmware-validation-pending_:
      runlevel = Job.RUNLEVEL-CRITICAL
    else if status > STATUS-GREEN:
      uptime := Duration --us=(Time.monotonic-us --since-wakeup)
      if uptime >= STATUS-NON-GREEN-MAX-UPTIME:
        // If we're experiencing problems connecting, the most
        // unjarring thing we can do is to force occassional
        // reboots of the system. Rebooting the system will reset
        // the uptime, so we end up only periodically rebooting.
        // This is in almost all ways better than disallowing
        // some or most containers from running, so this is our
        // starting point for all non-green statuses.
        runlevel = Job.RUNLEVEL-STOP
      else if status > STATUS-YELLOW:
        assert: status == STATUS-ORANGE or status == STATUS-RED
        runlevel = Job.RUNLEVEL-PRIORITY
        // If we're really, really having trouble synchronizing
        // we let the synchronizer run in critical mode every now
        // and then. It is our get-out-of-jail option, but we
        // really prefer running containers marked critical.
        if status == STATUS-RED and (random 100) < 15:
          runlevel = Job.RUNLEVEL-CRITICAL
    scheduler_.transition --runlevel=runlevel
    assert: runlevel != Job.RUNLEVEL-STOP  // Stop does not return.

    try:
      start := Time.monotonic-us
      limit := start + TIMEOUT-BROKER-CONNECT.in-us
      while not connect-network_ and Time.monotonic-us < limit:
        // If we didn't manage to connect to the broker, we
        // try to connect again. The next time, due to the
        // quarantining, we might pick a different network.
        logger_.info "connecting to broker failed - retrying"
        if Task.current.is-canceled:
          critical-do: logger_.warn "ignored cancelation in run loop"
          throw CANCELED-ERROR
    finally:
      if is-firmware-upgrade-pending_:
        exception := catch: firmware.upgrade
        logger_.error "firmware update: rebooting to apply update failed" --tags={"error": exception}
      if is-firmware-validation-pending_:
        logger_.error "firmware update: rejected after failing to connect or validate"
        exception := catch: firmware.rollback
        logger_.error "firmware update: rolling back failed" --tags={"error": exception}
        scheduler_.transition --runlevel=Job.RUNLEVEL-STOP

  /**
  Tries to connect to the network and run the synchronization.

  Returns whether we are done with this connection attempt (true)
    or if another attempt makes sense if time permits (false).
  */
  connect-network_ -> bool:
    network/net.Client? := null
    try:
      state_ = STATE-DISCONNECTED
      transition-to_ STATE-CONNECTING
      with-timeout TIMEOUT-NETWORK-OPEN: network = net.open
      while true:
        transition-to_ STATE-CONNECTED-TO-NETWORK
        done := connect-broker_ network
        if check-in:
          with-timeout TIMEOUT-CHECK-IN: check-in.run network logger_
        if done: return true
        if Task.current.is-canceled:
          critical-do: logger_.warn "ignored cancelation in connect-network loop"
          throw CANCELED-ERROR
    finally: | is-exception exception |
      // We get canceled in tests and when forced offline through calls
      // to $(control --online --close), so we need to maintain the proper
      // state and get the network correctly quarantined and closed.
      critical-do:
        error := (is-exception ? exception.value : null)
        if is-firmware-upgrade-pending_: error = null
        // We retry if we connected to the network, but failed
        // to actually connect to the broker. This could be an
        // indication that the network doesn't let us connect,
        // so we prefer using a different network for a while.
        done := state_ != STATE-CONNECTED-TO-NETWORK
        transition-to-disconnected_ --error=error
        // The synchronization may be interrupted by doing a
        // firmware upgrade or by a request to go offline. The
        // latter leads to cancelation.
        interrupted := is-firmware-upgrade-pending_ or Task.current.is-canceled
        if network:
          // If we are planning to retry another network, we
          // quarantine the one we just tried. We don't do
          // this if we were interrupted, because there is no
          // evidence that there is anything wrong with the
          // network in that case.
          if not done and not interrupted:
            with-timeout TIMEOUT-NETWORK-QUARANTINE: network.quarantine
          with-timeout TIMEOUT-NETWORK-CLOSE: network.close
        // If we're interrupted, we must make sure to propagate
        // the exception and not just swallow it. Otherwise, the
        // caller can easily run into a loop where it is repeatedly
        // asked to retry the connect.
        if not interrupted: return done

  /**
  Tries to connect to the broker and step through the
    necessary synchronization.

  Returns whether we are done synchronizing (true) or if we
    need another attempt using the already established network
    connection (false).
  */
  connect-broker_ network/net.Client -> bool:
    // TODO(kasper): Add timeout for connect.
    broker-connection := broker_.connect --network=network --device=device_
    try:
      goal/Goal? := null
      while true:
        with-timeout TIMEOUT-SYNCHRONIZE-STEP:
          if ntp_ and ntp_.schedule-now:
            ntp_.run network logger_
            continue
          goal = synchronize-step_ broker-connection goal
          if goal:
            assert: goal.has-pending-steps
            if Task.current.is-canceled:
              critical-do: logger_.warn "ignored cancelation in connect-broker loop (goal)"
              throw CANCELED-ERROR
            continue
          if device_.max-offline and control-level-online_ == 0: return true
          if check-in and check-in.schedule-now: return false
        if Task.current.is-canceled:
          critical-do: logger_.warn "ignored cancelation in connect-broker loop"
          throw CANCELED-ERROR
    finally:
      with-timeout TIMEOUT-BROKER-CLOSE: broker-connection.close

  /**
  Synchronizes with the broker.

  If $goal is provided, then we are in the middle of applying a goal. The
    goal then must have a pending step left to apply.
  Returns a goal state if we haven't finished.
  */
  synchronize-step_ broker-connection/BrokerConnection goal/Goal? -> Goal?:
    // TODO(florian): if we have an error here (like using `--goal_state=goal.goal_state`
    //    without checking for 'null' first), we end in a tight error loop.
    //    Is there any way we can protect ourselves better against coding errors
    //    in this part of the code? A different fall-back function?
    // [artemis.synchronize] WARN: connection to network lost {error: LOOKUP_FAILED}
    // [artemis.synchronize] INFO: disconnected
    // [artemis.synchronize] INFO: connecting to broker failed - retrying
    // [artemis.synchronize] INFO: connecting
    // [artemis.synchronize] INFO: connected to network
    // [artemis.synchronize] WARN: connection to network lost {error: LOOKUP_FAILED}
    // [artemis.synchronize] INFO: disconnected
    // [artemis.synchronize] INFO: connecting to broker failed - retrying
    // [artemis.synchronize] INFO: connecting
    // [artemis.synchronize] INFO: connected to network
    // [artemis.synchronize] WARN: connection to network lost {error: LOOKUP_FAILED}

   // If our state has changed, we communicate it to the cloud.
    report-state-if-changed broker-connection --goal-state=(goal and goal.goal-state)

    if goal:
      assert: goal.has-pending-steps

      // If we already have a goal state, it means that we're going
      // through the steps to get the current state updated to
      // match the goal state. We still allow the broker to give us
      // a new updated goal state in the middle of this, so we check
      // for that here.
      // If we are not yet allowed to go online don't wait for a goal.
      goal-state := broker-connection.fetch-goal-state --no-wait
      // Since we already have a goal we know that the device
      // was already updated. If we get a null from 'fetch_goal_state' it means
      // that it didn't connect to the broker, as Artemis never deletes a
      // goal once it has been set. (It only updates it.)
      if goal-state:
        transition-to-connected_
        goal = Goal goal-state
    else:
      // We don't have a goal state.
      goal-state := broker-connection.fetch-goal-state --wait
      transition-to-connected_
      if not goal-state:
        // No goal state from the broker.
        // Potentially a device that has been flashed and provisioned but hasn't been
        // updated through the broker yet.
        transition-to-synchronized_
        return null
      goal = Goal goal-state

    process-goal_ goal broker-connection
    // We only handle pending steps when we're done handling the other
    // updates. This means that we prioritize firmware updates and
    // state changes over dealing with any pending steps.
    if goal.has-pending-steps: return goal

    // We have successfully finished processing the new goal state
    // and any pending steps. Inform the broker.
    transition-to_ STATE-CONNECTED-TO-BROKER
    report-state-if-changed broker-connection
    transition-to-synchronized_
    return null

  transition-to_ state/int -> none:
    previous := state_
    state_ = state

    // We prefer to avoid polluting the logs when we're just
    // going back to a previous state. This way, we will show
    // how far we got in the synchronization process without
    // flipping too often between the synchronized and
    // connected to broker state.
    if state > previous:
      tags/Map? := null
      if state == STATE-SYNCHRONIZED:
        max-offline := device_.max-offline
        if max-offline and control-level-online_ == 0:
          tags = {"max-offline": max-offline}
      logger_.info STATE-SUCCESS[state] --tags=tags

    // If we've successfully connected to the broker, we consider
    // the current firmware functional. Go ahead and validate the
    // firmware if requested to do so.
    if is-firmware-validation-pending_ and state >= STATE-CONNECTED-TO-BROKER:
      if firmware.validate:
        device_.firmware-validated
        // We avoid marking the firmware as clean here, because we
        // prefer only doing that when the firmware service has
        // told us that no validation is pending. This is only done
        // from the constructor.
        is-firmware-validation-pending_ = false
        logger_.info "firmware update: validated after connecting to broker"
      else:
        logger_.error "firmware update: failed to validate"

  transition-to-connected_ -> none:
    if state_ >= STATE-CONNECTED-TO-BROKER: return
    transition-to_ STATE-CONNECTED-TO-BROKER

  transition-to-synchronized_ -> none:
    // Temporarily transition into the synchronized state. We do
    // not stick around in that state for very long, because after
    // being synchronized, we go back to just being connected to
    // the broker.
    transition-to_ STATE-SYNCHRONIZED

    // Keep track of the last time we succesfully synchronized.
    device_.synchronized-last-us-update JobTime.now.us

    // Go back to being connected to the broker. Having just
    // synchronized gives us confidence to run more jobs, so let
    // the scheduler know that we're in a good state.
    transition-to_ STATE-CONNECTED-TO-BROKER
    scheduler_.transition --runlevel=Job.RUNLEVEL-NORMAL

    watchdog_.feed

  transition-to-disconnected_ --error/Object? -> none:
    previous := state_
    state_ = STATE-DISCONNECTED
    if error: logger_.warn STATE-FAILURE[previous] --tags={"error": error}
    logger_.info STATE-SUCCESS[STATE-DISCONNECTED]

  determine-status_ -> int:
    last := device_.synchronized-last-us
    elapsed := JobTime.now.us
    if last: elapsed -= last
    limit := status-limit-us_
    if elapsed < limit:
      return STATUS-GREEN
    else if elapsed < (limit * 2):
      return STATUS-YELLOW
    else if elapsed < (limit * 3):
      return STATUS-ORANGE
    else:
      return STATUS-RED

  static compute-status-limit-us_ max-offline/Duration? -> int:
    // Compute the number of time units that correspond to
    // the max-offline setting by using ceiling division.
    max-offline-units := max-offline
        ? 1 + (max-offline.in-us - 1) / STATUS-LIMIT-UNIT-US
        : 1
    // Convert the units back to a number of microseconds and
    // derive the limit from that and the number of attempts
    // between status changes.
    max-offline-us := max-offline-units * STATUS-LIMIT-UNIT-US
    return max-offline-us * STATUS-CHANGES-AFTER-ATTEMPTS

  /**
  Starts the watchdog.

  The watchdog doesn't guarantee that we will connect to the broker, but
    rather makes sure that the device resets if it can't synchronize for
    some time. It is a redundant safety mechanism, as there is
    already a reboot strategy implemented.
  */
  static start-watchdog_ watchdog/Watchdog? max-offline/Duration? -> none:
    if not watchdog: return
    // TODO(florian): make this configurable?
    max-watchdog-offline := max-offline ? max-offline * 5 : Duration.ZERO
    max-watchdog-offline = max max-watchdog-offline (Duration --h=2)

    watchdog.start --s=max-watchdog-offline.in-s

  static stop-watchdog_ watchdog/Watchdog? -> none:
    if not watchdog: return
    watchdog.stop

  /**
  Process new goal.
  */
  process-goal_ goal/Goal broker-connection/BrokerConnection -> none:
    if goal.has-pending-steps:
      pending/Lambda := goal.remove-first-pending-step
      pending.call broker-connection
      return

    assert: state_ >= STATE-CONNECTED-TO-BROKER
    assert: not goal.has-pending-steps

    current-state := device_.current-state
    new-goal-state := goal.goal-state

    firmware-to := new-goal-state.get "firmware"
    if not firmware-to:
      transition-to_ STATE-PROCESSING-GOAL
      throw "missing firmware in goal"

    // We prioritize the firmware updating and deliberately avoid even
    // looking at the other parts of the updated goal state, because we
    // may not understand it before we've completed the firmware update.
    firmware-from := current-state["firmware"]
    if firmware-from != firmware-to:
      transition-to_ STATE-PROCESSING-FIRMWARE
      logger_.info "firmware update" --tags={"from": firmware-from, "to": firmware-to}
      report-state-if-changed broker-connection --goal-state=new-goal-state
      handle-firmware-update_ broker-connection firmware-to
      // Handling the firmware update always throws an exception. We
      // shouldn't get here.
      unreachable

    if device_.firmware-state["firmware"] != firmware-to:
      assert: firmware-from == firmware-to
      // The firmware has been downloaded and installed, but we haven't
      // rebooted yet. We ignore all other entries in the new goal state.
      return

    modification/Modification? := Modification.compute
        --from=current-state
        --to=new-goal-state
    if not modification:
      // No changes. All good.
      return

    transition-to_ STATE-PROCESSING-GOAL
    logger_.info "updating" --tags={"changes": Modification.stringify modification}
    report-state-if-changed broker-connection --goal-state=new-goal-state

    modification.on-map "apps"
        --added=: | name/string description |
          if description is not Map:
            logger_.error "updating: container $name has invalid description"
            continue.on-map
          description-map := description as Map
          description-map.get ContainerJob.KEY-ID
              --if-absent=:
                logger_.error "updating: container $name has no id"
              --if-present=:
                // A container just appeared in the state.
                id := parse-uuid_ it
                if id:
                  handle-container-install_ goal name id description-map
        --removed=: | name/string |
          // A container disappeared completely from the state. We
          // uninstall it.
          handle-container-uninstall_ name
        --modified=: | name/string nested/Modification |
          description := new-goal-state["apps"][name]
          handle-container-modification_ goal name description nested

    modification.on-value "max-offline"
        --added   =: handle-set-max-offline_ it
        --removed =: handle-set-max-offline_ null
        --updated =: | _ to | handle-set-max-offline_ to

  handle-container-modification_ -> none
      goal/Goal
      name/string
      description/Map
      modification/Modification:
    modification.on-value "id"
        --added=: | value |
          logger_.error "updating: container $name gained an id ($value)"
          // Treat it as a request to install the container.
          id := parse-uuid_ value
          if id: handle-container-install_ goal name id description
          return
        --removed=: | value |
          logger_.error "updating: container $name lost its id ($value)"
          // Treat it as a request to uninstall the container.
          handle-container-uninstall_ name
          return
        --updated=: | from to |
          // A container had its id (the code) updated. We uninstall
          // the old version and install the new one.
          // TODO(florian): it would be nicer to fetch the new version
          // before uninstalling the old one.
          handle-container-uninstall_ name
          id := parse-uuid_ to
          if id: handle-container-install_ goal name id description
          return

    handle-container-update_ name description

  handle-container-install_ goal/Goal name/string id/uuid.Uuid description/Map -> none:
    if job := containers_.create --name=name --id=id --description=description --state=null:
      device_.state-container-install-or-update name description
      containers_.install job
      return

    goal.add-pending-step:: | broker-connection/BrokerConnection |
      assert: state_ >= STATE-CONNECTED-TO-BROKER
      transition-to_ STATE-PROCESSING-CONTAINER-IMAGE
      broker-connection.fetch-image id: | reader/io.Reader |
        job := containers_.create
            --name=name
            --id=id
            --description=description
            --reader=reader
            --state=null
        device_.state-container-install-or-update name description
        containers_.install job

  handle-container-uninstall_ name/string -> none:
    job/ContainerJob? := containers_.get --name=name
    if job:
      containers_.uninstall job
    else:
      logger_.error "updating: container $name not found"
    device_.state-container-uninstall name

  handle-container-update_ name/string description/Map -> none:
    job/ContainerJob? := containers_.get --name=name
    if job:
      containers_.update job description
      device_.state-container-install-or-update name description
    else:
      logger_.error "updating: container $name not found"

  handle-set-max-offline_ value/any -> none:
    max-offline := (value is int) ? Duration --s=value : null
    device_.state-set-max-offline max-offline
    status-limit-us_ = compute-status-limit-us_ max-offline

  handle-firmware-update_ broker-connection/BrokerConnection new/string -> none:
    storage_.ram-store RAM-FIRMWARE-IS-CLEAN-KEY null  // Not necessarily clean anymore.
    if is-firmware-validation-pending_: throw "firmware update: cannot update unvalidated"
    runlevel := scheduler_.runlevel
    try:
      // TODO(kasper): We should make sure we're not increasing the
      // runlevel here. For now, that cannot happen because we're
      // using critical mode for firmware updates, but if we were to
      // change this, we shouldn't increase the runlevel here.
      scheduler_.transition --runlevel=Job.RUNLEVEL-CRITICAL
      firmware-update logger_ broker-connection --device=device_ --new=new
      is-firmware-upgrade-pending_ = true
      transition-to_ STATE-CONNECTED-TO-BROKER
      device_.state-firmware-update new
      report-state-if-changed broker-connection
      logger_.info "firmware update: rebooting to apply update"
      // We throw an exception to complete the firmware upgrade, because
      // we really want to tear down the broker connection and network
      // in an orderly fashion. Throwing an exception lets us unwind and
      // run all the cleanup code, before actually rebooting through a
      // call to firmware.upgrade in $run.
      throw "FIRMWARE_UPGRADE"
    finally:
      if not is-firmware-upgrade-pending_: scheduler_.transition --runlevel=runlevel

  /**
  Reports the current device state to the broker, but only if we know
    it may have changed.

  The reported state includes the firmware state, the current state,
    and the goal state.
  */
  report-state-if-changed broker-connection/BrokerConnection --goal-state/Map?=null -> none:
    state := {
      "firmware-state": device_.firmware-state,
    }
    if device_.pending-firmware:
      state["pending-firmware"] = device_.pending-firmware
    if device_.is-current-state-modified:
      state["current-state"] = device_.current-state
    if goal-state:
      state["goal-state"] = goal-state

    sha := sha256.Sha256
    sha.add (tison.encode state)
    checksum := sha.get
    if checksum == device_.report-state-checksum: return

    broker-connection.report-state state
    transition-to-connected_
    device_.report-state-checksum = checksum
    logger_.info "synchronized state to broker"
