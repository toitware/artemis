// Copyright (C) 2022 Toitware ApS. All rights reserved.

import gpio
import log
import reader show Reader SizedReader
import uuid

import system.containers

// --------------------------------------------------------------------------
// The Artemis package has temporarily been copied from the open
// source repository:
//
// https://github.com/toitware/toit-artemis/blob/main/src/
//
// When the API changes have solidified, the copied directory
// will be deleted in this repository and the new published
// version will be used instead.

// WAS: import artemis show Trigger
import artemis-pkg.artemis
  show
    Trigger
    TriggerInterval
    TriggerPin
    TriggerTouch

import .jobs
import .esp32.pin-trigger
import .scheduler
import ..shared.utils as utils

class ContainerManager:
  logger_/log.Logger
  scheduler_/Scheduler

  jobs_ ::= {:}           // Map<string, ContainerJob>
  images_ ::= {}          // Set<uuid.Uuid>
  images-bundled_ ::= {}  // Set<uuid.Uuid>
  pin-trigger-manager_/PinTriggerManager ::= ?

  constructor logger/log.Logger .scheduler_:
    logger_ = logger.with-name "containers"
    pin-trigger-manager_ = PinTriggerManager scheduler_ logger_
    containers.images.do: | image/containers.ContainerImage |
      images_.add image.id
      // TODO(kasper): It feels like a bit of a hack to determine
      // if an installed container image is bundled based on
      // whether or not it has a name.
      is-bundled := image.name != null
      if is-bundled: images-bundled_.add image.id

  load state/Map saved-states/Map -> none:
    apps := state.get "apps" --if-absent=: return
    apps.do: | name description |
      id/uuid.Uuid? := null
      catch: id = uuid.parse (description.get ContainerJob.KEY-ID)
      if not id: continue.do
      job := create --name=name --id=id --description=description --state=(saved-states.get name)
      // TODO(kasper): We should be able to find all container
      // images used by the current state in flash, so it isn't
      // very clear how we should handle it if we cannot. Should
      // we drop such an app from the current state? Seems like
      // the right thing to do.
      if job:
        if job.has-boot-trigger:
          job.trigger (Trigger.encode Trigger.KIND-BOOT)
        add_ job --message="load"

    // Mark containers that are needed by connections as runlevel safemode.
    // TODO(florian): should required containers be started on-demand?
    connections := state.get "connections"
    connections.do: | connection/Map |
      requires/List? := connection.get "requires"
      if requires:
        requires.do: | required-name/string |
          job := get --name=required-name
          if job: job.runlevel_ = Job.RUNLEVEL-SAFE

    pin-trigger-manager_.start jobs_.values

  setup-deep-sleep-triggers:
    non-delayed-jobs := jobs_.values.filter: | job/Job | job.scheduler-delayed-until_ == null
    pin-trigger-manager_.prepare-deep-sleep non-delayed-jobs

  get --name/string -> ContainerJob?:
    return jobs_.get name

  get --gid/int -> ContainerJob?:
    // TODO(kasper): Consider optimizing this through
    // the use of another map keyed by the gid.
    jobs_.do --values: | job/ContainerJob |
      if job.gid == gid: return job
    return null

  create -> ContainerJob?
      --name/string
      --id/uuid.Uuid
      --description/Map
      --state/any
      --reader/Reader?=null:
    if reader:
      writer/containers.ContainerImageWriter := ?
      if reader is SizedReader:
        size := (reader as SizedReader).size
        logger_.info "image download" --tags={"id": id, "size": size}
        writer = containers.ContainerImageWriter size
        while data := reader.read: writer.write data
      else:
        logger_.warn "image download with unknown size" --tags={"id": id}
        data := utils.read-all reader
        writer = containers.ContainerImageWriter data.size
        writer.write data
      image := writer.commit
      logger_.info "image downloaded" --tags={"id": image}
      if image != id: throw "invalid state"
      images_.add id
    else if not images_.contains id:
      return null
    return ContainerJob
        --name=name
        --id=id
        --description=description
        --pin-trigger-manager=pin-trigger-manager_
        --logger=logger_
        --state=state

  install job/ContainerJob -> none:
    if job.has-install-trigger:
      job.trigger (Trigger.encode Trigger.KIND-INSTALL)
    add_ job --message="install"

  uninstall job/ContainerJob -> none:
    remove_ job --message="uninstall"
    id := job.id
    // TODO(kasper): We could consider using reference counting
    // here instead of running through the jobs.
    preserve := images-bundled_.contains id
        or jobs_.any --values: it.id == id
    if preserve: return
    containers.uninstall job.id
    images_.remove id
    logger_.info "image uninstalled" --tags={"id": id}

  update job/ContainerJob description/Map -> none:
    scheduler_.remove-job job
    job.update description
    pin-trigger-manager_.update-job job
    // After updating the description of an app, we consider it
    // as newly installed. Rearm it if it has an install trigger.
    if job.has-install-trigger:
      job.trigger (Trigger.encode Trigger.KIND-INSTALL)
    logger_.info "update" --tags=job.tags
    scheduler_.add-job job

  add_ job/ContainerJob --message/string -> none:
    jobs_[job.name] = job
    scheduler_.add-job job
    logger_.info message --tags=job.tags

  remove_ job/ContainerJob --message/string -> none:
    jobs_.remove job.name
    scheduler_.remove-job job
    logger_.info message --tags=job.tags

class Triggers:
  trigger-boot/bool := false
  trigger-install/bool := false
  trigger-interval/Duration? := null
  trigger-gpio-levels/Map? := null
  trigger-gpio-touch/Set? := null

  constructor:

  constructor.from-description triggers/Map?:
    triggers.do: | name/string value |
      if name == "boot": trigger-boot = true
      if name == "install": trigger-install = true
      if name == "interval": trigger-interval = (Duration --s=value)
      if name.starts-with "gpio-high:":
        if not trigger-gpio-levels: trigger-gpio-levels = {:}
        trigger-gpio-levels[value] = 1
      if name.starts-with "gpio-low:":
        if not trigger-gpio-levels: trigger-gpio-levels = {:}
        trigger-gpio-levels[value] = 0
      if name.starts-with "gpio-touch:":
        if not trigger-gpio-touch: trigger-gpio-touch = {}
        trigger-gpio-touch.add value

  constructor.from-encoded-list triggers/List:
    triggers.do: | encoded/int |
      trigger := Trigger.decode encoded
      kind := trigger.kind
      if kind == Trigger.KIND-BOOT:
        trigger-boot = true
      else if kind == Trigger.KIND-INSTALL:
        trigger-install = true
      else if kind == Trigger.KIND-INTERVAL:
        trigger-interval = (trigger as TriggerInterval).interval
      else if kind == Trigger.KIND-PIN:
        pin := (trigger as TriggerPin).pin
        level := (trigger as TriggerPin).level
        if not trigger-gpio-levels: trigger-gpio-levels = {:}
        trigger-gpio-levels[pin] = level
      else if kind == Trigger.KIND-TOUCH:
        pin := (trigger as TriggerTouch).pin
        if not trigger-gpio-touch: trigger-gpio-touch = {}
        trigger-gpio-touch.add pin

  has-gpio-pin-triggers -> bool:
    return trigger-gpio-levels != null

  has-touch-triggers -> bool:
    return trigger-gpio-touch != null

  has-pin-trigger pin/int --level/int -> bool:
    return has-gpio-pin-triggers and (trigger-gpio-levels.get pin) == level

  has-touch-trigger pin/int -> bool:
    return has-touch-triggers and trigger-gpio-touch.contains pin

  to-encoded-list -> List:
    result := []
    if trigger-boot: result.add (Trigger.encode Trigger.KIND-BOOT)
    if trigger-install: result.add (Trigger.encode Trigger.KIND-INSTALL)
    if trigger-interval: result.add (Trigger.encode-interval trigger-interval)
    if trigger-gpio-levels:
      trigger-gpio-levels.do: | pin level |
        result.add (Trigger.encode-pin pin --level=level)
    if trigger-gpio-touch:
      trigger-gpio-touch.do: | pin |
        result.add (Trigger.encode-touch pin)
    return result

class ContainerJob extends Job:
  // The key of the ID in the $description.
  static KEY-ID ::= "id"

  pin-trigger-manager_/PinTriggerManager
  logger_/log.Logger

  id/uuid.Uuid
  description_/Map := ?
  running_/containers.Container? := null
  runlevel_/int := Job.RUNLEVEL-NORMAL

  is-background_/bool := false

  triggers-default_/Triggers := Triggers
  // The triggers that are currently active/armed. They might differ from the
  // default triggers if the user called `set-override-triggers`.
  triggers-armed_/Triggers := ?

  is-triggered_/bool := false
  // The reason for why this job was triggered.
  last-trigger-reason_/int? := null

  constructor
      --name/string
      --.id
      --description/Map
      --pin-trigger-manager/PinTriggerManager
      --logger/log.Logger
      --state/any:
    description_ = description
    pin-trigger-manager_ = pin-trigger-manager
    logger_ = logger.with-name name
    triggers-armed_ = triggers-default_
    super name state
    update description

  stringify -> string:
    return "container:$name"

  scheduler-state -> any:
    state := super
    triggers := identical triggers-armed_ triggers-default_
        ? null
        : triggers-armed_.to-encoded-list
    return [state, triggers]

  set-scheduler-state_ state/any -> none:
    if not state: return
    super state[0]
    triggers := state[1]
    triggers-armed_ = triggers == null
        ? triggers-default_
        : Triggers.from-encoded-list triggers

  is-running -> bool:
    return running_ != null

  is-background -> bool:
    return is-background_

  is-critical -> bool:
    return runlevel_ <= Job.RUNLEVEL-CRITICAL

  gid -> int?:
    running := running_
    return running and running.gid

  runlevel -> int:
    return runlevel_

  description -> Map:
    return description_

  tags -> Map:
    return { "name": name, "id": id }

  schedule now/JobTime last/JobTime? -> JobTime?:
    // TODO(kasper): Should the delayed restart take
    // precedence over all other triggers? Also, we
    // should probably think about how we want to access
    // the scheduler state here.
    if delayed-until := scheduler-delayed-until_:
      if delayed-until > now: return delayed-until
      trigger (Trigger.encode-delayed 0)
    else if is-critical:
      // TODO(kasper): Find a way to reboot the device if
      // a critical container keeps restarting.
      trigger (Trigger.encode Trigger.KIND-CRITICAL)
    else if trigger-interval := triggers-armed_.trigger-interval:
      result := last ? last + trigger-interval : now
      if result > now: return result
      trigger (Trigger.encode-interval trigger-interval)

    if is-triggered_: return now
    // TODO(kasper): Don't run at all. Maybe that isn't
    // a great default when you have no triggers?
    return null

  /**
  Triggers this job, making it run as soon as possible.
  */
  trigger reason/int:
    if is-running or is-triggered_: return
    is-triggered_ = true
    last-trigger-reason_ = reason

  /** An encoded list (see $Trigger.encode) of all triggers that are active for this job. */
  encoded-armed-triggers -> List:
    if scheduler-delayed-until_:
      // If the job is delayed, then no other trigger is active.
      remaining-time-ms := (scheduler-delayed-until_.to-monotonic-us - Time.monotonic-us) / 1000
      return [Trigger.encode-delayed remaining-time-ms]

    return triggers-armed_.to-encoded-list

  set-override-triggers new-encoded-triggers/List? -> none:
    if not new-encoded-triggers or triggers-default_.to-encoded-list == new-encoded-triggers:
      triggers-armed_ = triggers-default_
      return

    triggers-armed_ = Triggers.from-encoded-list new-encoded-triggers
    // Typically we are currently running, and don't need any trigger setup.
    // The following call is just in case of race conditions.
    if not running_:
      pin-trigger-manager_.update-job this

  schedule-tune last/JobTime -> JobTime:
    // If running the container took a long time, we tune the
    // schedule and postpone the next run by making it start
    // at the beginning of the next period instead of now.
    return Job.schedule-tune-periodic last triggers-armed_.trigger-interval

  start -> none:
    if running_: return

    arguments := description_.get "arguments"
    logger_.debug "starting" --tags={
      "reason": last-trigger-reason_,
      "arguments": arguments
    }

    // Update the triggers before we wake up the job.
    // Otherwise the job might not be able to access the pin.
    pin-trigger-manager_.update-job this

    // It is unlikely, but possible, that the container stops
    // prematurely before we've had the chance to report the job
    // as started. We handle this case by delaying the reporting
    // of the stopping until we've reported the starting.
    pending-on-stopped/Lambda? := null
    running_ = containers.start id arguments
        --on-event=:: | event-kind/int value |
          if event-kind == containers.Container.EVENT-BACKGROUND-STATE-CHANGE:
            is-background_ = value
            logger_.debug "state changed" --tags={"background": value}
            if running_: scheduler_.on-job-updated
        --on-stopped=::
          mark-stopped := ::
            running_ = null
            is-triggered_ = false
            pin-trigger-manager_.rearm-job this
            scheduler_.on-job-stopped this
          if running_:
            mark-stopped.call
          else:
            // Register the `mark-stopped` lambda as pending.
            pending-on-stopped = mark-stopped
    scheduler_.on-job-started this
    if pending-on-stopped: pending-on-stopped.call

  stop -> none:
    if not running_: return
    running_.stop  // Waits until the container has stopped.

  restart --wakeup-us/int? -> none:
    wakeup := JobTime.now
    if wakeup-us: wakeup += Duration --us=(wakeup-us - Time.monotonic-us)
    scheduler_.delay-job this --until=wakeup
    // If restart was called from the container being restarted,
    // we're in the middle of doing an RPC call here. Stopping
    // the container will cause the RPC processing task doing
    // the call to get canceled, so this better be the very last
    // thing we do.
    stop

  update description/Map -> none:
    assert: not is-running
    description_ = description
    is-background_ = description.contains "background"

    runlevel_ = description.get "runlevel" --if-absent=: Job.RUNLEVEL-NORMAL

    // TODO(florian): Remove updates of the runlevel_.
    // Update runlevel.
    if description.contains "critical":
      runlevel_ = Job.RUNLEVEL-CRITICAL

    // Reset triggers.
    triggers-default_ = is-critical
        ? Triggers
        : Triggers.from-description (description.get "triggers")
    triggers-armed_ = triggers-default_

  has-boot-trigger -> bool:
    return triggers-armed_.trigger-boot

  has-install-trigger -> bool:
    return triggers-armed_.trigger-install

  has-gpio-pin-triggers -> bool:
    return triggers-armed_.has-gpio-pin-triggers

  has-touch-triggers -> bool:
    return triggers-armed_.has-touch-triggers

  has-pin-triggers -> bool:
    return has-gpio-pin-triggers or has-touch-triggers

  has-pin-trigger pin/int --level/int -> bool:
    return triggers-armed_.has-pin-trigger pin --level=level

  has-touch-trigger pin/int -> bool:
    return triggers-armed_.has-touch-trigger pin

  do --trigger-gpio-levels/bool [block]:
    if not has-gpio-pin-triggers: return
    triggers-armed_.trigger-gpio-levels.do: | pin level |
      block.call pin level

  do --trigger-touch-pins/bool [block]:
    if not has-touch-triggers: return
    triggers-armed_.trigger-gpio-touch.do: | pin |
      block.call pin

  touch-triggers -> Set:
    return triggers-armed_.trigger-gpio-touch
