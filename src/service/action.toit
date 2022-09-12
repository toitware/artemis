// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .application
import .synchronize show logger

abstract class Action:
  static apply actions/List map/Map -> Map:
    copy := map.copy
    actions.do: | action/Action |
      action.perform copy
    return copy

  abstract perform map/Map -> none

abstract class ActionApplication extends Action:
  name/string
  manager/ApplicationManager ::= ApplicationManager.instance
  constructor .name:

  install map/Map id/string:
    map[name] = id
    manager.install (Application name id)

  uninstall map/Map id/string:
    map.remove name
    application/Application? := manager.lookup id
    if application: manager.uninstall application

class ActionApplicationInstall extends ActionApplication:
  new/string
  constructor name/string .new:
    super name

  perform map/Map -> none:
    logger.info "app install: request" --tags={"name": name, "new": new}
    install map new

class ActionApplicationUpdate extends ActionApplication:
  new/string
  old/string
  constructor name/string .new .old:
    super name

  perform map/Map -> none:
    logger.info "app install: request" --tags={"name": name, "new": new, "old": old}
    uninstall map old

class ActionApplicationUninstall extends ActionApplication:
  old/string
  constructor name/string .old:
    super name

  perform map/Map -> none:
    logger.info "app uninstall" --tags={"name": name}
    uninstall map old
