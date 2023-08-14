// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import ..ui

create-doc-commands _ _ ui/Ui -> List:
  cmd := cli.Command "doc"
      --short-help="Documentation."

  specification-format-cmd := cli.Command "specification-format"
      --short-help="Show the format of the pod specification file."
      --run=:: ui.result SPECIFICATION-FORMAT-HELP
  cmd.add specification-format-cmd

  return [cmd]

SPECIFICATION-FORMAT-HELP ::= """
  The format of the pod specification file.

  The specification file is a JSON file with the following entries:

  'version': The version of the specification file. Must be '1'.
  'sdk-version': The SDK version to use. This is a string of the form
      'v<major>.<minor>.<patch>'; for example 'v1.2.3'.
  'artemis-version': The Artemis service version to use. This is a typically
      a string of the form 'v<major>.<minor>.<patch>'; for example 'v1.2.3'.
  'max-offline': The duration the device can be offline before it
      attempts to connect to the broker to sync. Expressed as
      string of the form '1h2m3s' or '1h 2m 3s'.
  'connections': a list of connections, each of which must be a
      connection object. See below for the format of a connection object.
  'containers': a list of containers, each of which must be a container
      object. See below for the format of a container object.


  A connection object consists of the following entries:
  'type': The type of the connection. Must be 'wifi', 'cellular', or
    'ethernet'.

  For 'wifi' connections:
  'ssid': The SSID of the network to connect to.
  'password': The password of the network to connect to.

  For 'cellular' connections:
  'config': The configuration of the cellular driver. Depends on
      the cellular driver.

  Container entries are compiled to containers that are installed in
  the firmware. They can either be snapshot or source containers. (See
  below).
  They always have a 'name' entry which is the name of the container.
  They may have an 'arguments' entry; a list of strings that are passed
  to the container when it is started.
  They may have a 'triggers' entry, consisting of a list of triggers. See
  below for the format of a trigger object.
  They may have a 'background' boolean entry. If true, the container
  does not keep the device awake. If only background tasks are running the
  device goes to deep sleep.
  They may have a 'critical' boolean entry. If true, the container
  is considered critical and prioritized by the system. Critical containers
  run all the time and they thus cannot have triggers. They run at a
  lower runlevel (for example in safemode) than other containers.

  Snapshot containers have a 'snapshot' entry which must be a path to the
  snapshot file.
  Source containers have an 'entrypoint' entry which must be a path to the
  entrypoint file.
  Source containers may also have a 'git' and 'branch' entry (which can be a
  branch or tag) to checkout a git repository first.

  A triggers entry can be either a string, or a map.
  String-triggers:
  - 'boot': Run the container when the device boots.
  - 'install': Run the container when the container is installed.

  Map-triggers are maps in the trigger list. Depending on which key is
  present, the map is interpreted as one of the following triggers:
  - 'interval': Run the container every interval. The interval is specified
      as value of the 'interval' key. The value is a string of the form
      '1h2m3s' or '1h 2m 3s'.
  - 'gpio': Run the container depending on GPIO triggers. The value of
      the 'gpio' key is a list of GPIO triggers. Each GPIO trigger is a
      map with the following entries:
      'pin': The pin to trigger on.
      'level': The level to trigger on. Must be 'high' or 'low'.
  """
