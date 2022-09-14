// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .applications

class ActionBundle:
  config_/Map
  actions_/List ::= []
  constructor .config_:

  add action/Action:
    actions_.add action

  commit -> Map:
    actions_.do: | action/Action | action.perform
    return config_

abstract class Action:
  abstract perform -> none

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
