// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show *

create-doc-commands -> List:
  cmd := Command "doc"
      --help="Documentation."

  specification-format-cmd := Command "specification-format"
      --help="Show the format of the pod specification file."
      --run=:: | invocation/Invocation |
        invocation.cli.ui.emit --result SPECIFICATION-FORMAT-HELP
  cmd.add specification-format-cmd

  return [cmd]

SPECIFICATION-FORMAT-HELP ::= """
  The format of the pod specification file.

  The specification file is a YAML or JSON file with the following entries:

  '\$schema': The json-schema (used as version) of the specification file.
      Must be 'https://toit.io/schemas/artemis/pod-specification/v1.json'.

  'sdk-version': The SDK version to use. This is a string of the form
      'v<major>.<minor>.<patch>'; for example 'v1.2.3'.
  'artemis-version': The Artemis service version to use. This is a typically
      a string of the form 'v<major>.<minor>.<patch>'; for example 'v1.2.3'.
      Use 'sdk list' to see all available sdk-artemis combinations.
  'firmware-envelope': optional. The firmware envelope to use. This can be a
      variant name available from https://github.com/toitlang/envelopes (for
      example 'esp32-no-ble'), a path URI to a local envelope (for
      example 'file:///path/to/envelope'), or a URI to a remote envelope (for
      example 'https://example.com/envelope').
      For URIs any '\$(sdk-version)' is replaced with the SDK version.
  'partitions': optional. The partition table to use. This can be a
      CSV file published on https://github.com/toitlang/envelopes (for
      example 'esp32-ota-1c0000"), a path URI to a local partition file (for
      example 'file:///path/to/partition-table'), or a URI to a remote
      partition table (for example 'https://example.com/partition-table.csv').

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
      and they thus cannot have triggers. By default, they run at a lower
      runlevel ("critical") than other containers.
  'runlevel': optional. Either a positive integer or a symbolic name
      for the runlevel ("critical", "priority", or "normal"). The runlevel is
      used to determine which containers to consider when making scheduling
      decisions. A container is only schedulable if its runlevel is lower
      than or equal to the scheduler's current runlevel. The scheduler may
      choose to adjust its runlevel based on a number a factors, including,
      but not limited to, how succesful the latest attempts at synchronizing
      with the cloud have been.
  'snapshot': optional. A path to a snapshot file. The path is relative
      to the specification file.
  'git': optional. A git repository to checkout before running the container.
  'branch': optional. The branch or tag to checkout. If 'git' is specified,
      'branch' must also be specified.
  'entrypoint': optional. A path to a source directory. The path is
      relative to the specification file, or to the git repository if
      'git' is specified.
  'compile-flags': optional. A list of strings that are passed to the
      compiler when compiling the source container.

  The 'snapshot' and 'entrypoint' entries are mutually exclusive.
  If 'git' is specified, 'entrypoint' must be specified and be a relative path.
  The 'compile-flags' entry is only valid if 'entrypoint' is specified.

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
