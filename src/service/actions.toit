// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show SizedReader
import monitor

import .applications
import .resources show ResourceFetcher

class ActionManager:
  channel_ ::= monitor.Channel 16  // TODO(kasper): Maybe this should be unbounded?
  signal_/monitor.Signal ::= monitor.Signal
  asynchronous_/int := 0

  has_next -> bool:
    return channel_.size > 0

  next -> ActionBundle?:
    return channel_.receive

  add bundle/ActionBundle?:
    channel_.send bundle

  commit bundle/ActionBundle -> Map:
    bundle.actions_.do: | action/Action | action.run
    signal_.wait: asynchronous_ == 0
    return bundle.config_

  on_started action/ActionAsynchronous:
    asynchronous_++

  on_stopped action/ActionAsynchronous:
    if --asynchronous_ == 0: signal_.raise

class ActionBundle:
  config_/Map
  actions_/List ::= []
  constructor .config_:

  add action/Action:
    actions_.add action

abstract class Action:
  abstract perform -> none
  run -> none: perform

abstract class ActionApplication extends Action:
  manager/ApplicationManager
  name/string
  constructor .manager .name:

  install id/string:
    manager.install (Application name id)

  uninstall id/string:
    application/Application? := manager.get id
    if application: manager.uninstall application

class ActionApplicationInstall extends ActionApplication:
  new/string
  constructor manager/ApplicationManager name/string .new:
    super manager name

  perform -> none:
    install new

class ActionApplicationUpdate extends ActionApplication:
  id/string
  constructor manager/ApplicationManager name/string .id:
    super manager name

  perform -> none:
    application/Application? := manager.get id
    if application: manager.update application

class ActionApplicationUninstall extends ActionApplication:
  old/string
  constructor manager/ApplicationManager name/string .old:
    super manager name

  perform -> none:
    uninstall old

abstract class ActionAsynchronous extends Action:
  actions/ActionManager
  constructor .actions:

  run -> none:
    actions.on_started this
    task::
      try:
        perform
      finally:
        actions.on_stopped this

class ActionFetchApplications extends ActionAsynchronous:
  applications/ApplicationManager
  fetcher/ResourceFetcher
  constructor .applications actions/ActionManager .fetcher:
    super actions

  perform -> none:
    incomplete/Application? ::= applications.first_incomplete
    if not incomplete: return
    fetcher.fetch_resource incomplete.path: | reader/SizedReader |
      applications.complete incomplete reader
