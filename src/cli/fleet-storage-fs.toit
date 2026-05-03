// Copyright (C) 2026 Toit contributors.

import cli show Cli
import host.file
import uuid show Uuid

import .fleet-storage show FleetStorage
import .utils show read-json write-json-to-file write-blob-to-file

FLEET-FILE_ ::= "fleet.json"
DEVICES-FILE_ ::= "devices.json"

read-json-map_ path/string --cli/Cli -> Map:
  contents/any := null
  exception := catch: contents = read-json path
  if exception:
    cli.ui.emit --error "Fleet file '$path' is not a valid JSON."
    cli.ui.emit --error exception.message
    cli.ui.abort
  if contents is not Map:
    cli.ui.abort "Fleet file '$path' has invalid format."
  return contents as Map

/**
A $FleetStorage backed by a fleet-root directory on the local filesystem.

Reads and writes fleet.json, devices.json, and per-pod yaml specs as
  files under the fleet root. Identity files are written to the
  user-supplied output directory.
*/
class FilesystemFleetStorage implements FleetStorage:
  root_/string
  cli_/Cli

  constructor --root/string --cli/Cli:
    if not file.is-directory root:
      cli.ui.abort "Fleet root '$root' is not a directory."
    root_ = root
    cli_ = cli

  display-root -> string?: return root_

  supports-devices -> bool: return true

  fleet-config-path_ -> string: return "$root_/$FLEET-FILE_"
  devices-path_ -> string: return "$root_/$DEVICES-FILE_"
  pod-spec-path_ name/string -> string: return "$root_/$(name).yaml"

  has-fleet-config -> bool: return file.is-file fleet-config-path_

  read-fleet-config -> Map:
    return read-json-map_ fleet-config-path_ --cli=cli_

  write-fleet-config config/Map -> none:
    write-json-to-file --pretty fleet-config-path_ config

  has-devices -> bool: return file.is-file devices-path_

  read-devices -> Map:
    return read-json-map_ devices-path_ --cli=cli_

  write-devices devices/Map -> none:
    write-json-to-file --pretty devices-path_ devices

  has-pod-spec name/string -> bool:
    return file.is-file (pod-spec-path_ name)

  write-pod-spec name/string contents/ByteArray -> none:
    write-blob-to-file (pod-spec-path_ name) contents

  write-identity --device-id/Uuid contents/ByteArray --output-directory/string -> string:
    out-path := "$output-directory/$(device-id).identity"
    write-blob-to-file out-path contents
    return out-path

/**
A $FleetStorage backed by a single fleet reference file.

Reference files describe a fleet's brokers and id, but cannot be used
  for device management. Device-related operations and writes (other
  than the fleet config itself, which can be re-rendered as a reference
  via $write-fleet-config) abort.
*/
class ReferenceFleetStorage implements FleetStorage:
  reference-path_/string
  cli_/Cli

  constructor --reference-path/string --cli/Cli:
    if not file.is-file reference-path:
      cli.ui.abort "Fleet reference '$reference-path' is not a file."
    reference-path_ = reference-path
    cli_ = cli

  display-root -> string?: return reference-path_

  supports-devices -> bool: return false

  has-fleet-config -> bool: return file.is-file reference-path_

  read-fleet-config -> Map:
    return read-json-map_ reference-path_ --cli=cli_

  write-fleet-config config/Map -> none:
    cli_.ui.abort "Reference fleets cannot be modified."

  has-devices -> bool: return false

  read-devices -> Map:
    cli_.ui.abort "Reference fleets do not have a devices file."
    unreachable

  write-devices devices/Map -> none:
    cli_.ui.abort "Reference fleets do not support device management."

  has-pod-spec name/string -> bool: return false

  write-pod-spec name/string contents/ByteArray -> none:
    cli_.ui.abort "Reference fleets do not support pod specifications."

  write-identity --device-id/Uuid contents/ByteArray --output-directory/string -> string:
    cli_.ui.abort "Reference fleets do not support identity files."
    unreachable
