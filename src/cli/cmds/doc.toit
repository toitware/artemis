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
      Use 'sdk list' to see all available sdk-artemis combinations.
  'firmware-envelope': optional. The firmware envelope to use. This can be a
      variant name available from https://github.com/toitlang/envelopes (for
      example 'esp32s3-spiram-octo', a path URI to a local envelope (for
      example 'file:///path/to/envelope'), or a URI to a remote envelope (for
      example 'https://example.com/envelope').
      For URIs any '\$(sdk-version)' is replaced with the SDK version.

  'extends': optional. A list of paths to other specification files to
      extend. The paths are relative to the current specification file.
      The extended files are merged into the current file in order. Newer
      entries win over older entries. The current file wins over the extended
      files.
      Lists and maps are merged.
      A 'null' entry can be used to signal that the entry should not be
      extended.

  'max-offline': optional. The duration the device can be offline before it
      attempts to connect to the broker to sync. Expressed as
      string of the form '1h2m3s' or '1h 2m 3s'.
      If no value is specified, the default is '0s'.
  'connections': a list of connections, each of which must be a
      connection object. At least one connection must be provided.
      See below for the format of a connection object.
  'containers': optional. a list of containers, each of which must be a container
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
  below). Containers have the following entries:
  'name': The name of the container. Must be unique.
  'arguments': optional. A list of strings that are passed to the
      container when it is started.
  'triggers': optional. A list of triggers. See below for the format
      of a trigger object. If no triggers are specified, the container
      is started automatically at install time and when the device boots.
  'background': optional. If true, the container does not keep the
      device awake. The device goes to deep-sleep when no non-background
      task is running.
  'critical': optional. If true, the container is considered critical
      and prioritized by the system. Critical containers run all the time
      and they thus cannot have triggers. They run at a lower runlevel
      (for example in safemode) than other containers.
  'snapshot': optional. A path to a snapshot file. The path is relative
      to the specification file.
  'git': optional. A git repository to checkout before running the container.
  'branch': optional. The branch or tag to checkout. If 'git' is specified,
      'branch' must also be specified.
  'entrypoint': optional. A path to a source directory. The path is
      relative to the specification file, or to the git repository if
      'git' is specified.

  The 'snapshot' and 'entrypoint' entries are mutually exclusive.
  If 'git' is specified, 'entrypoint' must be specified and be a relative path.

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
