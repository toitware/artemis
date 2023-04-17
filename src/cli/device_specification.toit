// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.base64
import encoding.json
import encoding.url as url_encoding
import host.file
import fs

import .cache as cli
import .cache show GIT_APP_PATH
import .firmware
import .sdk
import .server_config
import .utils
import .git
import .ui

class DeviceSpecificationException:
  message/string

  constructor .message:

  stringify -> string:
    return message

format_error_ message/string:
  throw (DeviceSpecificationException message)

validation_error_ message/string:
  throw (DeviceSpecificationException message)

check_has_key_ map/Map --holder/string="device specification" key/string:
  if not map.contains key:
    format_error_ "Missing $key in $holder."

check_is_map_ map/Map key/string --entry_type/string="Entry":
  get_map_ map key --entry_type=entry_type

get_int_ map/Map key/string -> int
    --holder/string="device specification"
    --entry_type/string="Entry":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not int:
    format_error_ "$entry_type $key in $holder is not an int: $value"
  return value

get_string_ map/Map key/string -> string
    --holder/string="device specification"
    --entry_type/string="Entry":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not string:
    format_error_ "$entry_type $key in $holder is not a string: $value"
  return value

get_optional_string_ map/Map key/string -> string?
    --holder/string="device specification"
    --entry_type/string="Entry":
  if not map.contains key: return null
  return get_string_ map key --holder=holder --entry_type=entry_type

get_optional_list_ map/Map key/string --type/string [--check] -> List?
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key: return null
  value := map[key]
  if value is not List:
    format_error_ "$entry_type $key in $holder is not a list: $value"
  value.do:
    if not check.call it:
      format_error_ "$entry_type $key in $holder is not a list of $(type)s: $value"
  return value

get_map_ map/Map key/string -> Map
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not Map:
    format_error_ "$entry_type $key in $holder is not a map: $value"
  return value

get_optional_map_ map/Map key/string -> Map?
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key: return null
  return get_map_ map key --entry_type=entry_type --holder=holder

get_list_ map/Map key/string -> List
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not List:
    format_error_ "$entry_type $key in $holder is not a list: $value"
  return value

get_duration_ map/Map key/string -> Duration
    --entry_type/string="Entry"
    --holder/string="device specification":
  // Parses a string like "1h 30m 10s" or "1h30m10s" into seconds.
  // Returns 0 if the string is empty.

  if not map.contains key:
    format_error_ "Missing $key in $holder."

  entry := map[key]
  if entry is not string:
    format_error_ "$entry_type $key in $holder is not a string: $entry"

  entry_string := entry as string
  entry_string = entry_string.trim
  if entry_string == "": return Duration.ZERO

  return parse_duration entry_string --on_error=:
    format_error_ "$entry_type $key in $holder is not a valid duration: $entry"

get_optional_duration_ map/Map key/string -> Duration?
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key: return null
  return get_duration_ map key --entry_type=entry_type --holder=holder

get_optional_bool_ map/Map key/string -> bool?
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key: return null
  return get_bool_ map key --entry_type=entry_type --holder=holder

get_bool_ map/Map key/string -> bool
    --entry_type/string="Entry"
    --holder/string="device specification":
  if not map.contains key:
    format_error_ "Missing $key in $holder."
  value := map[key]
  if value is not bool:
    format_error_ "$entry_type $key in $holder is not a boolean: $value"
  return value

/**
A specification of a device.

This class contains the information needed to install/flash and
  update a device.

Relevant data includes (but is not limited to):
- the SDK version (which currently gives the firmware binary),
- max offline,
- connection information (Wi-Fi, cellular, ...),
- installed containers.
*/
class DeviceSpecification:
  sdk_version/string
  artemis_version/string
  max_offline_seconds/int
  connections/List  // Of $ConnectionInfo.
  containers/Map  // Of name -> $Container.
  path/string
  chip/string?

  constructor.from_json --.path/string data/Map:
    sdk_version = get_string_ data "sdk-version"
    artemis_version = get_string_ data "artemis-version"

    chip = get_optional_string_ data "chip"

    if data.contains "apps" and data.contains "containers":
      format_error_ "Both 'apps' and 'containers' are present in device specification."

    if (get_int_ data "version") != 1:
      format_error_ "Unsupported device specification version $data["version"]"

    if data.contains "apps" and not data.contains "containers":
      check_is_map_ data "apps"
      data = data.copy
      data["containers"] = data["apps"]
      data.remove "apps"
    else if data.contains "containers":
      check_is_map_ data "containers"

    containers_entry := data.get "containers"
    if not containers_entry: containers_entry = {:}

    containers_entry.do --keys:
      check_is_map_ containers_entry --entry_type="Container" it

    containers = containers_entry.map: | name container_description |
          Container.from_json name container_description

    connections_entry := get_list_ data "connections"
    connections_entry.do:
      if it is not Map:
        format_error_ "Connection in device specification is not a map: $it"

    connections = data["connections"].map: ConnectionInfo.from_json it

    // TODO(florian): make max-offline optional.
    max_offline_seconds = (get_duration_ data "max-offline").in_s

    validate_

  static parse path/string -> DeviceSpecification:
    json := null
    exception := catch: json = read_json path
    if exception:
      format_error_ "Failed to parse device specification as JSON: $exception"
    return DeviceSpecification.from_json --path=path json

  /**
  Returns the path to which all other paths of this specification are
    relative to.
  */
  relative_to -> string:
    return fs.dirname path

  /**
  Checks non-syntax related invariants of the specification.
  */
  validate_ -> none:
    connections.do: | connection/ConnectionInfo |
      if connection.requires:
        connection.requires.do: | required_container_name/string |
          if not containers.contains required_container_name:
            validation_error_ "Cellular connection requires container $required_container_name, but it is not installed."

interface ConnectionInfo:
  static from_json data/Map -> ConnectionInfo:
    check_has_key_ data --holder="connection" "type"

    if data["type"] == "wifi":
      return WifiConnectionInfo.from_json data
    if data["type"] == "cellular":
      return CellularConnectionInfo.from_json data
    format_error_ "Unknown connection type: $data["type"]"
    unreachable

  type -> string
  requires -> List?  // Of container names.
  to_json -> Map

class WifiConnectionInfo implements ConnectionInfo:
  ssid/string
  password/string

  constructor.from_json data/Map:
    ssid = get_string_ data "ssid" --holder="wifi connection"
    password = get_string_ data "password" --holder="wifi connection"

  type -> string:
    return "wifi"

  to_json -> Map:
    return {"type": type, "ssid": ssid, "password": password}

  requires -> List?:
    return null

class CellularConnectionInfo implements ConnectionInfo:
  config/Map
  requires/List?

  constructor.from_json data/Map:
    config = get_map_ data "config" --holder="cellular connection"
    requires = get_optional_list_ data "requires"
        --holder="cellular connection"
        --type="string"
        --check=: it is string

  type -> string:
    return "cellular"

  to_json -> Map:
    return {"type": type, "config": config, "requires": requires}

interface Container:
  static RUNLEVEL_STOP     ::= 0
  static RUNLEVEL_SAFE     ::= 1
  static RUNLEVEL_CRITICAL ::= 2
  static RUNLEVEL_NORMAL   ::= 3

  static STRING_TO_RUNLEVEL_ ::= {
    "stop": RUNLEVEL_STOP,
    "safe": RUNLEVEL_SAFE,
    "critical": RUNLEVEL_CRITICAL,
    "normal": RUNLEVEL_NORMAL,
  }

  static from_json name/string data/Map -> Container:
    if data.contains "entrypoint" and data.contains "snapshot":
      format_error_ "Container $name has both entrypoint and snapshot."

    if data.contains "entrypoint":
      return ContainerPath.from_json name data
    if data.contains "snapshot":
      return ContainerSnapshot.from_json name data

    format_error_ "Unsupported container $name: $data"
    unreachable

  /**
  Builds a snapshot and stores it at the given $output_path.

  All paths in the container are relative to $relative_to.
  */
  build_snapshot --output_path/string --relative_to/string --sdk/Sdk --cache/cli.Cache --ui/Ui
  type -> string
  arguments -> List?
  is_background -> bool?
  is_critical -> bool?
  runlevel -> int?
  triggers -> List? // Of type $Trigger.

  static check_arguments_entry arguments:
    if arguments == null: return
    if arguments is not List:
      format_error_ "Arguments entry must be a list: $arguments"
    arguments.do: | argument |
      if argument is not string:
        format_error_ "Arguments entry must be a list of strings: $arguments"

abstract class ContainerBase implements Container:
  arguments/List?
  triggers/List?
  is_background/bool?
  is_critical/bool?
  runlevel/int?

  constructor.from_json name/string data/Map:
    holder := "container $name"
    arguments = get_optional_list_ data "arguments"
        --holder=holder
        --type="string"
        --check=: it is string
    is_background = get_optional_bool_ data "background"
    is_critical = get_optional_bool_ data "critical"
    runlevel_string := get_optional_string_ data "run-level"
    if runlevel_string:
      runlevel = Container.STRING_TO_RUNLEVEL_.get runlevel_string
          --if_absent=: format_error_ "Unknown run-level '$runlevel_string' in container $name"
    else:
      runlevel = null
    triggers_list := get_optional_list_ data "triggers"
        --holder=holder
        --type="map or string"
        --check=: it is Map or it is string
    if triggers_list:
      if is_critical:
        format_error_ "Critical container $name cannot have triggers"
      triggers = []
      parsed_triggers := triggers_list.map: Trigger.parse_json name it
      seen_types := {}
      parsed_triggers.do: | trigger_entry |
        trigger_type/string := ?
        if trigger_entry is List:
          // Gpio triggers.
          trigger_type = "gpio"
          triggers.add_all trigger_entry
        else:
          trigger/Trigger := trigger_entry
          trigger_type = trigger.type
          triggers.add trigger

        if seen_types.contains trigger_type:
          format_error_ "Duplicate trigger '$trigger_type' in container $name"
        seen_types.add trigger_type
    else:
      triggers = null

  abstract type -> string
  abstract build_snapshot --output_path/string --relative_to/string --sdk/Sdk --cache/cli.Cache --ui/Ui

class ContainerPath extends ContainerBase:
  entrypoint/string
  git_url/string?
  git_ref/string?

  constructor.from_json name/string data/Map:
    holder := "container $name"
    git_ref = get_optional_string_ data "branch" --holder=holder
    git_url = get_optional_string_ data "git" --holder=holder
    entrypoint = get_string_ data "entrypoint" --holder=holder
    if git_url and not git_ref:
      format_error_ "In container $name, git entry requires a branch/tag: $git_url"
    if git_url and not fs.is_relative entrypoint:
      format_error_"In container $name, git entry requires a relative path: $entrypoint"
    super.from_json name data

  build_snapshot --output_path/string --relative_to/string --sdk/Sdk --cache/cli.Cache --ui/Ui:
    if not git_url:
      path := entrypoint
      if fs.is_relative path:
        path = "$relative_to/$path"
      sdk.compile_to_snapshot path --out=output_path
      return

    git := Git --ui=ui
    git_key := "$GIT_APP_PATH/$git_url"
    ui.info "Fetching $git_url."
    cached_checkout := cache.get_directory_path git_key: | store/cli.DirectoryStore |
      store.with_tmp_directory: | tmp_dir/string |
        clone_dir := "$tmp_dir/clone"
        git.init clone_dir --origin=git_url --quiet
        git.config --repository_root=clone_dir
            --key="advice.detachedHead"
            --value="false"
        git.fetch
            --repository_root=clone_dir
            --depth=1
            --ref=git_ref
            --quiet
        store.move clone_dir
    // Make sure we have the ref we need in the cache.
    git.fetch --force --depth=1 --ref=git_ref --repository_root=cached_checkout
    // In case the remote updated the ref, update the local tag.
    git.tag
        --update
        --name=git_ref
        --ref="origin/$git_ref"
        --repository_root=cached_checkout
        --force

    with_tmp_directory: | tmp_dir/string |
      // Clone the repository to a temporary directory, so we
      // aren't affected by changes to the cache.
      clone_dir := "$tmp_dir/clone"
      file_uri := "file://$(url_encoding.encode cached_checkout)"
      git.init clone_dir --origin=file_uri --quiet
      git.config --repository_root=clone_dir
          --key="advice.detachedHead"
          --value="false"
      git.fetch
          --checkout
          --depth=1
          --repository_root=clone_dir
          --ref=git_ref
          --quiet
      ui.info "Compiling $git_url."
      entrypoint_path := "$clone_dir/$entrypoint"
      if not file.is_file entrypoint_path:
        ui.error "No such file: $entrypoint_path"
        ui.abort

      package_yaml_path := "$clone_dir/package.yaml"
      if not file.is_file package_yaml_path:
        if file.is_directory package_yaml_path:
          ui.error "package.yaml is a directory in $git_url"
          ui.abort
        // Create an empty package.yaml file, so that we can safely call
        // toit.pkg without worrying that we use some file from a folder
        // above our tmp directory.
        write_blob_to_file package_yaml_path #[]

      sdk.pkg_install --project_root=clone_dir

      // TODO(florian): move into the clone_dir and compile from there.
      // Otherwise we have unnecessary absolute paths in the snapshot.
      sdk.compile_to_snapshot entrypoint_path --out=output_path

  type -> string:
    return "path"

class ContainerSnapshot extends ContainerBase:
  snapshot_path/string

  constructor.from_json name/string data/Map:
    holder := "container $name"
    snapshot_path = get_string_ data "snapshot" --holder=holder
    super.from_json name data

  build_snapshot --relative_to/string --output_path/string --sdk/Sdk --cache/cli.Cache --ui/Ui:
    path := snapshot_path
    if fs.is_relative snapshot_path:
      path = "$relative_to/$snapshot_path"
    copy_file --source=path --target=output_path

  type -> string:
    return "snapshot"

abstract class Trigger:
  abstract type -> string
  /**
  A value that is associated with the trigger.
  This is the value that is sent in the goal state.
  Triggers that don't have any value should use 1.
  */
  abstract json_value -> any

  constructor:

  /**
  Parses the given trigger in JSON format.

  May either return a single $Trigger or a list of triggers.
  */
  static parse_json container_name/string data/any -> any:
    known_triggers := {
      "boot": :: BootTrigger,
      "install": :: InstallTrigger,
      "interval": :: IntervalTrigger.from_json container_name it,
      "gpio": :: GpioTrigger.parse_json container_name it,
    }
    map_triggers := { "interval", "gpio" }

    seen_types := {}
    trigger/Lambda? := null
    known_triggers.do: | key/string value/Lambda |
      is_map_trigger := map_triggers.contains key
      if is_map_trigger:
        if data is Map and data.contains key:
          seen_types.add key
          trigger = value
      else if data is string and data == key:
        seen_types.add key
        trigger = value
    if seen_types.size == 0:
      format_error_ "Unknown trigger in container $container_name: $data"
    if seen_types.size != 1:
      format_error_ "Container $container_name has ambiguous trigger: $data"

    return trigger.call data

class IntervalTrigger extends Trigger:
  interval/Duration

  constructor .interval:

  constructor.from_json container_name/string data/Map:
    holder := "trigger in container $container_name"
    interval = get_duration_ data "interval" --holder=holder

  type -> string:
    return "interval"

  json_value -> int:
    return interval.in_s

class BootTrigger extends Trigger:
  type -> string:
    return "boot"

  json_value -> int:
    return 1

class InstallTrigger extends Trigger:
  // We use a unique nonce for the install trigger, so
  // we can be sure that re-installing a container
  // causes a modification to the goal state.
  nonce_/string

  constructor:
    id := random_uuid --namespace="install nonce"
    nonce_ = base64.encode id.to_byte_array

  type -> string:
    return "install"

  json_value -> string:
    return nonce_

abstract class GpioTrigger extends Trigger:
  pin/int

  constructor .pin:

  static parse_json container_name/string data/Map -> List:
    holder := "container $container_name"
    gpio_trigger_list := get_list_ data "gpio" --holder=holder
    // Check that all entries are maps.
    gpio_trigger_list.do: | entry |
      if entry is not Map:
        format_error_ "Entry in gpio trigger list of $holder is not a map"

    pin_triggers := gpio_trigger_list.map: | entry/Map |
      pin_holder := "gpio trigger in container $container_name"
      pin := get_int_ entry "pin" --holder=pin_holder
      pin_holder = "gpio trigger for pin $pin in container $container_name"
      on_touch := get_optional_bool_ entry "touch" --holder=pin_holder
      level_string := get_optional_string_ entry "level" --holder=pin_holder
      on_high := ?
      if on_touch:
        if level_string != null:
          format_error_ "Both level $level_string and touch are set in $holder"
          unreachable
        on_high = null
      else:
        if level_string == "high" or level_string == null:
          on_high = true
        else if level_string == "low":
          on_high = false
        else:
          format_error_ "Invalid level in $holder: $level_string"
          unreachable

      if on_high: GpioTriggerHigh pin
      else if on_touch: GpioTriggerTouch pin
      else: GpioTriggerLow pin

    seen_pins := {}
    pin_triggers.do: | trigger/GpioTrigger |
      if seen_pins.contains trigger.pin:
        format_error_ "Duplicate pin in gpio trigger of $holder"
      seen_pins.add trigger.pin

    return pin_triggers

  type -> string:
    return "$pin_trigger_kind:$pin"

  json_value -> int:
    // Use the pin as value, so that the service doesn't need to decode it.
    return pin

  abstract pin_trigger_kind -> string

class GpioTriggerHigh extends GpioTrigger:
  constructor pin/int: super pin

  pin_trigger_kind -> string: return "gpio-high"

class GpioTriggerLow extends GpioTrigger:
  constructor pin/int: super pin

  pin_trigger_kind -> string: return "gpio-low"

class GpioTriggerTouch extends GpioTrigger:
  constructor pin/int: super pin

  pin_trigger_kind -> string: return "gpio-touch"
