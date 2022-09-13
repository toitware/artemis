// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .applications
import .synchronize show logger

abstract class Action:
  static apply actions/List map/Map? -> Map:
    copy := map ? map.copy : {:}
    actions.do: | action/Action |
      action.perform copy
    return copy

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
    logger.info "app install: request" --tags={"name": name, "new": new}
    install map new

class ActionApplicationUpdate extends ActionApplication:
  new/string
  old/string
  constructor manager/ApplicationManager name/string .new .old:
    super manager name

  perform map/Map -> none:
    logger.info "app install: request" --tags={"name": name, "new": new, "old": old}
    uninstall map old

class ActionApplicationUninstall extends ActionApplication:
  old/string
  constructor manager/ApplicationManager name/string .old:
    super manager name

  perform map/Map -> none:
    logger.info "app uninstall" --tags={"name": name}
    uninstall map old
