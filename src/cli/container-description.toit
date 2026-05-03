// Copyright (C) 2026 Toit contributors.

import uuid show Uuid

import .pod-specification show Trigger

/**
Builds a container description as needed for an "app" entry in the
  device goal state.

Used both at envelope-customize time (to pre-bake apps into the firmware)
  and at sync time (to push container-install changes to the broker).
*/
build-container-description -> Map
    --id/Uuid
    --arguments/List?
    --background/bool?
    --critical/bool?
    --runlevel/int?
    --triggers/List?:
  result := {
    "id": id.stringify,
  }
  if arguments and not arguments.is-empty:
    result["arguments"] = arguments
  if background:
    result["background"] = 1
  if critical:
    result["critical"] = 1
  if runlevel:
    result["runlevel"] = runlevel
  if triggers and not triggers.is-empty:
    trigger-map := {:}
    triggers.do: | trigger/Trigger |
      assert: not trigger-map.contains trigger.type
      trigger-map[trigger.type] = trigger.json-value
    result["triggers"] = trigger-map
  return result
