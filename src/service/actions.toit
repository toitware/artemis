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

  install config/Map:
    manager.install (Application name config)

  uninstall config/Map:
    id := config[Application.CONFIG_ID]
    application/Application? := manager.get id
    if application: manager.uninstall application

class ActionApplicationInstall extends ActionApplication:
  new/Map
  constructor manager/ApplicationManager name/string .new:
    super manager name

  perform -> none:
    install new

class ActionApplicationUpdate extends ActionApplication:
  new/Map
  old/Map
  constructor manager/ApplicationManager name/string .new .old:
    super manager name

  perform -> none:
    uninstall old

class ActionApplicationUninstall extends ActionApplication:
  old/Map
  constructor manager/ApplicationManager name/string .old:
    super manager name

  perform -> none:
    uninstall old
