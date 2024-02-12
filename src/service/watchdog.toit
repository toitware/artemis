// Copyright (C) 2024 Toitware ApS. All rights reserved.

import watchdog show WatchdogServiceClient Watchdog

class WatchdogManager:
  static instance/WatchdogManager ::= WatchdogManager.private_

  static STATE-BOOT ::= 0
  static STATE-STARTUP ::= 1
  static STATE-SCHEDULER ::= 2
  static STATE-STOP ::= 3

  static STARTUP_TIMEOUT_S ::= 10
  static SCHEDULER_TIMEOUT_S ::= 10
  static STOP_TIMEOUT_S ::= 3

  state ::= STATE-BOOT
  main-dog_/Watchdog? := null

  client_ ::= (WatchdogServiceClient).open as WatchdogServiceClient

  constructor.private_:

  static transition-to new-state/int -> Watchdog:
    return instance.transition-to_ new-state

  transition-to_ new-state/int -> Watchdog:
    if new-state == STATE-STARTUP:
      assert: state == STATE-BOOT and main-dog_ == null
      main-dog_ = client_.create "toit.io/artemis/startup"
      main-dog_.start --s=STARTUP-TIMEOUT-S
      return main-dog_
    if new-state == STATE-SCHEDULER:
      assert: state == STATE-STARTUP and main-dog_ != null
      scheduler-dog := client_.create "toit.io/artemis/scheduler"
      scheduler-dog.start --s=SCHEDULER-TIMEOUT-S
      main-dog_.stop
      main-dog_.close
      main-dog_ = scheduler-dog
      return scheduler-dog
    if new-state == STATE-STOP:
      assert: state == STATE-SCHEDULER and main-dog_ != null
      stop-dog := client_.create "toit.io/artemis/stop"
      stop-dog.start --s=STOP-TIMEOUT-S
      main-dog_.stop
      main-dog_.close
      main-dog_ = stop-dog
      return stop-dog
    throw "Unknown state"

  static create-dog name/string -> Watchdog:
    return instance.client_.create name
