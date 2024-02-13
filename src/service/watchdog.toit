// Copyright (C) 2024 Toitware ApS. All rights reserved.

import watchdog show WatchdogServiceClient Watchdog
import system

class WatchdogManager:
  static instance/WatchdogManager ::= WatchdogManager.private_

  static STATE-BOOT ::= 0
  static STATE-STARTUP ::= 1
  static STATE-SCHEDULER ::= 2
  static STATE-STOP ::= 3

  static TIMEOUT-STARTUP-S ::= 10
  static TIMEOUT-SCHEDULER-S ::= 10
  static TIMEOUT-STOP-S ::= 3

  static STATE-DOG-NAMES ::= {
    STATE-BOOT: null,
    STATE-STARTUP: "toit.io/artemis/startup",
    STATE-SCHEDULER: "toit.io/artemis/scheduler",
    STATE-STOP: "toit.io/artemis/stop",
  }

  static STATE-TIMEOUTS-S ::= {
    STATE-STARTUP: TIMEOUT-STARTUP-S,
    STATE-SCHEDULER: TIMEOUT-SCHEDULER-S,
    STATE-STOP: TIMEOUT-STOP-S
  }


  main-dog_/Watchdog? := null

  client_/WatchdogServiceClient ::= (WatchdogServiceClient).open as WatchdogServiceClient

  constructor.private_:

  static transition-to new-state/int -> Watchdog:
    return instance.transition-to_ new-state

  transition-to_ new-state/int -> Watchdog:
    new-name := STATE-DOG-NAMES[new-state]
    new-timeout-s := STATE-TIMEOUTS-S[new-state]
    new-dog := client_.create new-name
    new-dog.start --s=new-timeout-s
    if main-dog_:
      main-dog_.stop
      main-dog_.close
      main-dog_ = null
    main-dog_ = new-dog
    return new-dog

  static create-dog name/string -> Watchdog:
    return instance.client_.create name

  /**
  Resets the manager.

  After this call no watchdog is running.
  This function should primarly be used for testing, on host systems.
  */
  static reset -> none:
    instance.reset_

  reset_ -> none:
    if main-dog_:
      main-dog_.stop
      main-dog_.close
      main-dog_ = null

