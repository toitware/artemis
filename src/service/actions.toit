// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .applications

class ActionBundle:
  section_/string
  actions_/List ::= []
  constructor .section_:

  add action/Action:
    actions_.add action

  commit map/Map -> none:
    section := map.get section_
    copy := section ? section.copy : {:}
    actions_.do: | action/Action |
      action.perform copy
    map[section_] = copy

abstract class Action:
  abstract perform map/Map -> none

abstract class ActionApplication extends Action:
  manager/ApplicationManager
  name/string
  constructor .manager .name:

  install map/Map id/string:
    map[name] = id
    manager.install (Application name id)

  uninstall map/Map id/string:
    map.remove name
    application/Application? := manager.get id
    if application: manager.uninstall application

class ActionApplicationInstall extends ActionApplication:
  new/string
  constructor manager/ApplicationManager name/string .new:
    super manager name

  perform map/Map -> none:
    install map new

class ActionApplicationUpdate extends ActionApplication:
  new/string
  old/string
  constructor manager/ApplicationManager name/string .new .old:
    super manager name

  perform map/Map -> none:
    uninstall map old

class ActionApplicationUninstall extends ActionApplication:
  old/string
  constructor manager/ApplicationManager name/string .old:
    super manager name

  perform map/Map -> none:
    uninstall map old
