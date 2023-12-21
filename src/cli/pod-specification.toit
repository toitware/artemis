// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.base64
import encoding.json
import encoding.url as url-encoding
import host.file
import fs
import semver

import .cache as cli
import .cache show GIT-APP-PATH
import .firmware
import .sdk
import .server-config
import .utils
import .git
import .ui

import ..shared.version show SDK-VERSION ARTEMIS-VERSION

INITIAL-POD-NAME ::= "my-pod"
INITIAL-POD-SPECIFICATION -> Map:
  return {
    "version": 1,
    "name": "$INITIAL-POD-NAME",
    "sdk-version": SDK-VERSION,
    "artemis-version": ARTEMIS-VERSION,
    "max-offline": "0s",
    "connections": [
      {
        "type": "wifi",
        "ssid": "YOUR WIFI SSID",
        "password": "YOUR WIFI PASSWORD",
      }
    ],
    "containers": {:},
  }

EXAMPLE-POD-SPECIFICATION -> Map:
  return {
    "version": 1,
    "name": "example-pod",
    "sdk-version": SDK-VERSION,
    "artemis-version": ARTEMIS-VERSION,
    "max-offline": "30s",
    "connections": [
      {
        "type": "wifi",
        "ssid": "YOUR WIFI SSID",
        "password": "YOUR WIFI PASSWORD",
      }
    ],
    "containers": {
      "hello": {
        "entrypoint": "hello.toit",
        "triggers": [
          "boot",
          {
            "interval": "1m",
          },
        ],
      },
      "solar": {
        "entrypoint": "examples/solar_example.toit",
        "git": "https://github.com/toitware/toit-solar-position.git",
        "branch": "v0.0.3",
        "triggers": [
          {
            "gpio": [
              {
                "pin": 33,
                "level": "high",
              },
            ],
          },
        ],
      },
    },
  }

class PodSpecificationException:
  message/string

  constructor .message:

  stringify -> string:
    return message

format-error_ message/string:
  throw (PodSpecificationException message)

validation-error_ message/string:
  throw (PodSpecificationException message)

check-has-key_ map/Map --holder/string="pod specification" key/string:
  // We use `map.get` so that specifications can "delete" entries they have
  // included by overriding them with 'null'.
  if (map.get key) == null:
    format-error_ "Missing $key in $holder."

has-key_ map/Map key/string -> bool:
  return (map.get key) != null

check-is-map_ map/Map key/string --entry-type/string="Entry":
  get-map_ map key --entry-type=entry-type

get-int_ map/Map key/string -> int
    --holder/string="pod specification"
    --entry-type/string="Entry":
  check-has-key_ map --holder=holder key
  value := map[key]
  if value is not int:
    format-error_ "$entry-type $key in $holder is not an int: $value"
  return value

get-string_ map/Map key/string -> string
    --holder/string="pod specification"
    --entry-type/string="Entry":
  check-has-key_ map --holder=holder key
  value := map[key]
  if value is not string:
    format-error_ "$entry-type $key in $holder is not a string: $value"
  return value

get-optional-string_ map/Map key/string -> string?
    --holder/string="pod specification"
    --entry-type/string="Entry":
  if not has-key_ map key: return null
  return get-string_ map key --holder=holder --entry-type=entry-type

get-optional-list_ map/Map key/string --type/string [--check] -> List?
    --entry-type/string="Entry"
    --holder/string="pod specification":
  if not has-key_ map key: return null
  value := map[key]
  if value is not List:
    format-error_ "$entry-type $key in $holder is not a list: $value"
  value.do:
    if not check.call it:
      format-error_ "$entry-type $key in $holder is not a list of $(type)s: $value"
  return value

get-map_ map/Map key/string -> Map
    --entry-type/string="Entry"
    --holder/string="pod specification":
  check-has-key_ map --holder=holder key
  value := map[key]
  if value is not Map:
    format-error_ "$entry-type $key in $holder is not a map: $value"
  return value

get-optional-map_ map/Map key/string -> Map?
    --entry-type/string="Entry"
    --holder/string="pod specification":
  if not has-key_ map key: return null
  return get-map_ map key --entry-type=entry-type --holder=holder

get-list_ map/Map key/string -> List
    --entry-type/string="Entry"
    --holder/string="pod specification":
  check-has-key_ map --holder=holder key
  value := map[key]
  if value is not List:
    format-error_ "$entry-type $key in $holder is not a list: $value"
  return value

get-duration_ map/Map key/string -> Duration
    --entry-type/string="Entry"
    --holder/string="pod specification":
  // Parses a string like "1h 30m 10s" or "1h30m10s" into seconds.
  // Returns 0 if the string is empty.

  check-has-key_ map --holder=holder key

  entry := map[key]
  if entry is not string:
    format-error_ "$entry-type $key in $holder is not a string: $entry"

  entry-string := entry as string
  entry-string = entry-string.trim
  if entry-string == "": return Duration.ZERO

  return parse-duration entry-string --on-error=:
    format-error_ "$entry-type $key in $holder is not a valid duration: $entry"

get-optional-duration_ map/Map key/string -> Duration?
    --entry-type/string="Entry"
    --holder/string="pod specification":
  if not has-key_ map key: return null
  return get-duration_ map key --entry-type=entry-type --holder=holder

get-optional-bool_ map/Map key/string -> bool?
    --entry-type/string="Entry"
    --holder/string="pod specification":
  if not has-key_ map key: return null
  return get-bool_ map key --entry-type=entry-type --holder=holder

get-bool_ map/Map key/string -> bool
    --entry-type/string="Entry"
    --holder/string="pod specification":
  check-has-key_ map --holder=holder key
  value := map[key]
  if value is not bool:
    format-error_ "$entry-type $key in $holder is not a boolean: $value"
  return value

/**
Merges the json object $other into $target.

The parameters $other and $target must both be maps.

- if a key is present in both:
  - if both values are maps then the values are merged recursively,
  - if both values are lists then the lists are concatenated,
  - otherwise the value from $target is used,
- if a key is present only in $other, the value is copied as-is, unless it's
  null in which case it's ignored.
*/
merge-json-into_ target/Map other/Map -> none:
  other.do: | key value |
    if target.contains key:
      target-value := target[key]
      if target-value is Map and value is Map:
        merge-json-into_ target-value value
      else if target-value is List and value is List:
        target[key] = target-value + value
      else:
        // Do nothing: keep the value from target.
    else if value != null:
      target[key] = value

/**
Removes all entries for which the value is null.
*/
remove-null-values_ o/any -> none:
  null-keys := []
  if o is Map:
    map := o as Map
    map.do: | key value |
      if value == null:
        null-keys.add key
      else:
        remove-null-values_ value

    null-keys.do: | key |
      map.remove key

  if o is List:
    list := o as List
    list.filter --in-place: it != null
    list.do: remove-null-values_ it

/**
A specification of a pod.

This class contains the information needed to install/flash and
  update a device.

Relevant data includes (but is not limited to):
- the SDK version (which currently gives the firmware binary),
- max offline,
- connection information (Wi-Fi, cellular, ethernet, ...),
- installed containers.
*/
class PodSpecification:
  name/string
  sdk-version/string?
  envelope/string?
  artemis-version/string
  max-offline-seconds/int
  connections/List  // Of $ConnectionInfo.
  containers/Map  // Of name -> $Container.
  path/string
  chip/string?

  constructor.from-json --.path/string data/Map:
    name = get-string_ data "name"
    artemis-version = get-string_ data "artemis-version"
    sdk-version = get-optional-string_ data "sdk-version"
    envelope = get-optional-string_ data "firmware-envelope"

    if sdk-version and not semver.is-valid sdk-version:
      format-error_ "Invalid sdk-version: $sdk-version"

    if not sdk-version and not envelope:
      format-error_ "Neither 'sdk-version' nor 'firmware-envelope' are present in pod specification."

    chip = get-optional-string_ data "chip"

    if has-key_ data "apps" and has-key_ data "containers":
      format-error_ "Both 'apps' and 'containers' are present in pod specification."

    if (get-int_ data "version") != 1:
      format-error_ "Unsupported pod specification version $data["version"]"

    if has-key_ data "apps" and not has-key_ data "containers":
      check-is-map_ data "apps"
      data = data.copy
      data["containers"] = data["apps"]
      data.remove "apps"
    else if has-key_ data "containers":
      check-is-map_ data "containers"

    containers-entry := data.get "containers"
    if not containers-entry: containers-entry = {:}

    containers-entry.do --keys:
      check-is-map_ containers-entry --entry-type="Container" it

    containers = containers-entry.map: | name container-description |
      Container.from-json name container-description

    connections-entry := get-list_ data "connections"
    connections-entry.do:
      if it is not Map:
        format-error_ "Connection in pod specification is not a map: $it"

    connections = data["connections"].map: ConnectionInfo.from-json it

    max-offline := get-optional-duration_ data "max-offline"
    max-offline-seconds = max-offline ? max-offline.in-s : 0

    validate_

  static parse path/string -> PodSpecification:
    json := parse-json-hierarchy path
    return PodSpecification.from-json --path=path json

  static parse-json-hierarchy path/string --extends-chain/List=[] -> Map:
    path = fs.clean path

    fail := : | error-message/string |
      extends-chain.do --reversed: | include-path/string |
        error-message += "\n  - Extended by $include-path."
      format-error_ error-message

    json := null
    exception := catch:
      json = read-json path
    if exception:
      fail.call "Failed to read pod specification from $path: $exception."

    if json is not Map:
      fail.call "Pod specification at $path does not contain a map."

    extends-entries := json.get "extends"

    if extends-entries and extends-entries is not List:
      fail.call "Extends entry in pod specification at $path is not a list."

    if extends-entries:
      extends-chain.add path

      base-specs := extends-entries.map: | extends-path/string |
        if fs.is-relative extends-path:
          extends-path = fs.join (fs.dirname path) extends-path
        if extends-chain.contains extends-path:
          fail.call "Circular extends: $extends-path."
        parse-json-hierarchy extends-path --extends-chain=extends-chain

      extends-chain.resize (extends-chain.size - 1)

      base-specs.do: | base-spec/Map |
        merge-json-into_ json base-spec

      json.remove "extends"
    if extends-chain.is-empty:
      remove-null-values_ json
    return json

  /**
  Returns the path to which all other paths of this specification are
    relative to.
  */
  relative-to -> string:
    return fs.dirname path

  /**
  Checks non-syntax related invariants of the specification.
  */
  validate_ -> none:
    connections.do: | connection/ConnectionInfo |
      if connection.requires:
        connection.requires.do: | required-container-name/string |
          if (containers.get required-container-name) == null:
            validation-error_ "Connection requires container $required-container-name, but it is not installed."

interface ConnectionInfo:
  static from-json data/Map -> ConnectionInfo:
    check-has-key_ data --holder="connection" "type"

    type := data["type"]
    if type == "wifi":
      return WifiConnectionInfo.from-json data
    if type == "cellular":
      return CellularConnectionInfo.from-json data
    if type == "ethernet":
      return EthernetConnectionInfo.from-json data
    format-error_ "Unknown connection type: $type"
    unreachable

  type -> string
  requires -> List?  // Of container names.
  to-json -> Map

class WifiConnectionInfo implements ConnectionInfo:
  ssid/string?
  password/string?

  constructor.from-json data/Map:
    config := get-optional-string_ data "config" --holder="wifi connection"
    if config:
      if config != "provisioned": format-error_ "Unknown wifi config: $config"
      ssid = null
      password = null
    else:
      ssid = get-string_ data "ssid" --holder="wifi connection"
      password = get-string_ data "password" --holder="wifi connection"

  type -> string:
    return "wifi"

  to-json -> Map:
    return {"type": type, "ssid": ssid, "password": password}

  requires -> List?:
    return null

class CellularConnectionInfo implements ConnectionInfo:
  config/Map
  requires/List?

  constructor.from-json data/Map:
    config = get-map_ data "config" --holder="cellular connection"
    requires = get-optional-list_ data "requires"
        --holder="cellular connection"
        --type="string"
        --check=: it is string

  type -> string:
    return "cellular"

  to-json -> Map:
    result := {
      "type": type,
      "config": config,
    }
    if requires: result["requires"] = requires
    return result

class EthernetConnectionInfo implements ConnectionInfo:
  requires/List?

  constructor.from-json data/Map:
    requires = get-optional-list_ data "requires"
        --holder="ethernet connection"
        --type="string"
        --check=: it is string

  type -> string:
    return "ethernet"

  to-json -> Map:
    result := {
      "type": type,
    }
    if requires: result["requires"] = requires
    return result

interface Container:
  // Must match the corresponding constants in src/service/jobs.toit.
  static RUNLEVEL-CRITICAL ::= 1
  static RUNLEVEL-PRIORITY ::= 2
  static RUNLEVEL-NORMAL   ::= 3

  static STRING-TO-RUNLEVEL_ ::= {
    "critical": RUNLEVEL-CRITICAL,
    "priority": RUNLEVEL-PRIORITY,
    "normal": RUNLEVEL-NORMAL,
  }

  static from-json name/string data/Map -> Container:
    if has-key_ data "entrypoint" and has-key_ data "snapshot":
      format-error_ "Container $name has both entrypoint and snapshot."

    if has-key_ data "entrypoint":
      return ContainerPath.from-json name data
    if has-key_ data "snapshot":
      return ContainerSnapshot.from-json name data

    format-error_ "Unsupported container $name: $data"
    unreachable

  /**
  Builds a snapshot and stores it at the given $output-path.

  All paths in the container are relative to $relative-to.
  */
  build-snapshot --output-path/string --relative-to/string --sdk/Sdk --cache/cli.Cache --ui/Ui
  type -> string
  arguments -> List?
  is-background -> bool?
  is-critical -> bool?
  runlevel -> int?
  triggers -> List? // Of type $Trigger.
  defines -> Map?

  static check-arguments-entry arguments:
    if arguments == null: return
    if arguments is not List:
      format-error_ "Arguments entry must be a list: $arguments"
    arguments.do: | argument |
      if argument is not string:
        format-error_ "Arguments entry must be a list of strings: $arguments"

abstract class ContainerBase implements Container:
  arguments/List?
  triggers/List?
  is-background/bool?
  is-critical/bool?
  runlevel/int?
  defines/Map?
  name/string

  constructor.from-json .name data/Map:
    holder := "container $name"
    arguments = get-optional-list_ data "arguments"
        --holder=holder
        --type="string"
        --check=: it is string
    is-background = get-optional-bool_ data "background"
    is-critical = get-optional-bool_ data "critical"

    runlevel-key := "runlevel"
    if has-key_ data runlevel-key:
      value := data[runlevel-key]
      if value is int:
        if value <= 0: format_error_ "Entry $runlevel-key in $holder must be positive"
        runlevel = value
      else if value is string:
        runlevel = Container.STRING-TO-RUNLEVEL_.get value
            --if-absent=: format-error_ "Unknown $runlevel-key in $holder: $value"
      else:
        format-error_ "Entry $runlevel-key in $holder is not an int or a string: $value"
        unreachable
    else:
      runlevel = null

    triggers-list := get-optional-list_ data "triggers"
        --holder=holder
        --type="map or string"
        --check=: it is Map or it is string
    if triggers-list:
      if is-critical:
        format-error_ "Critical container $name cannot have triggers"
      triggers = []
      parsed-triggers := triggers-list.map: Trigger.parse-json name it
      seen-types := {}
      parsed-triggers.do: | trigger-entry |
        trigger-type/string := ?
        if trigger-entry is List:
          // Gpio triggers.
          trigger-type = "gpio"
          triggers.add-all trigger-entry
        else:
          trigger/Trigger := trigger-entry
          trigger-type = trigger.type
          triggers.add trigger

        if seen-types.contains trigger-type:
          format-error_ "Duplicate trigger '$trigger-type' in container $name"
        seen-types.add trigger-type
    else:
      triggers = null

    defines = get-optional-map_ data "defines"

  abstract type -> string
  abstract build-snapshot --output-path/string --relative-to/string --sdk/Sdk --cache/cli.Cache --ui/Ui

class ContainerPath extends ContainerBase:
  entrypoint/string
  git-url/string?
  git-ref/string?
  compile-flags/List?

  constructor.from-json name/string data/Map:
    holder := "container $name"
    git-ref = get-optional-string_ data "branch" --holder=holder
    git-url = get-optional-string_ data "git" --holder=holder
    entrypoint = get-string_ data "entrypoint" --holder=holder
    compile-flags = get-optional-list_ data "compile-flags"
        --holder=holder
        --type="string"
        --check=: it is string
    if git-url and not git-ref:
      format-error_ "In container $name, git entry requires a branch/tag: $git-url"
    if git-url and not fs.is-relative entrypoint:
      format-error_"In container $name, git entry requires a relative path: $entrypoint"
    super.from-json name data

  build-snapshot --output-path/string --relative-to/string --sdk/Sdk --cache/cli.Cache --ui/Ui:
    if not git-url:
      path := entrypoint
      if fs.is-relative path:
        path = "$relative-to/$path"
      exception := catch:
        sdk.compile-to-snapshot path
            --flags=compile-flags
            --out=output-path
      if exception: ui.abort "Compilation of container $name failed: $exception."
      return

    git := Git --ui=ui
    git-key := "$GIT-APP-PATH/$git-url"
    ui.info "Fetching $git-url."
    cached-checkout := cache.get-directory-path git-key: | store/cli.DirectoryStore |
      store.with-tmp-directory: | tmp-dir/string |
        clone-dir := "$tmp-dir/clone"
        git.init clone-dir --origin=git-url --quiet
        git.config --repository-root=clone-dir
            --key="advice.detachedHead"
            --value="false"
        git.fetch
            --repository-root=clone-dir
            --depth=1
            --ref=git-ref
            --quiet
        store.move clone-dir
    // Make sure we have the ref we need in the cache.
    git.fetch --force --depth=1 --ref=git-ref --repository-root=cached-checkout
    // In case the remote updated the ref, update the local tag.
    git.tag
        --update
        --name=git-ref
        --ref="origin/$git-ref"
        --repository-root=cached-checkout
        --force

    with-tmp-directory: | tmp-dir/string |
      // Clone the repository to a temporary directory, so we
      // aren't affected by changes to the cache.
      clone-dir := "$tmp-dir/clone"
      file-uri := "file://$(url-encoding.encode cached-checkout)"
      git.init clone-dir --origin=file-uri --quiet
      git.config --repository-root=clone-dir
          --key="advice.detachedHead"
          --value="false"
      git.fetch
          --checkout
          --depth=1
          --repository-root=clone-dir
          --ref=git-ref
          --quiet
      ui.info "Compiling $git-url."
      entrypoint-path := "$clone-dir/$entrypoint"
      if not file.is-file entrypoint-path:
        ui.abort "Entry point $entrypoint-path does not exist."

      package-yaml-path := "$clone-dir/package.yaml"
      if not file.is-file package-yaml-path:
        if file.is-directory package-yaml-path:
          ui.abort "package.yaml is a directory in $git-url."
        // Create an empty package.yaml file, so that we can safely call
        // toit.pkg without worrying that we use some file from a folder
        // above our tmp directory.
        write-blob-to-file package-yaml-path #[]

      sdk.pkg-install --project-root=clone-dir

      // TODO(florian): move into the clone_dir and compile from there.
      // Otherwise we have unnecessary absolute paths in the snapshot.
      exception := catch:
        sdk.compile-to-snapshot entrypoint-path
            --flags=compile-flags
            --out=output-path
      if exception: ui.abort "Compilation of container $name failed: $exception."

  type -> string:
    return "path"

class ContainerSnapshot extends ContainerBase:
  snapshot-path/string

  constructor.from-json name/string data/Map:
    holder := "container $name"
    snapshot-path = get-string_ data "snapshot" --holder=holder
    super.from-json name data

  build-snapshot --relative-to/string --output-path/string --sdk/Sdk --cache/cli.Cache --ui/Ui:
    path := snapshot-path
    if fs.is-relative snapshot-path:
      path = "$relative-to/$snapshot-path"
    copy-file --source=path --target=output-path

  type -> string:
    return "snapshot"

abstract class Trigger:
  abstract type -> string
  /**
  A value that is associated with the trigger.
  This is the value that is sent in the goal state.
  Triggers that don't have any value should use 1.
  */
  abstract json-value -> any

  constructor:

  /**
  Parses the given trigger in JSON format.

  May either return a single $Trigger or a list of triggers.
  */
  static parse-json container-name/string data/any -> any:
    known-triggers := {
      "boot": :: BootTrigger,
      "install": :: InstallTrigger,
      "interval": :: IntervalTrigger.from-json container-name it,
      "gpio": :: GpioTrigger.parse-json container-name it,
    }
    map-triggers := { "interval", "gpio" }

    seen-types := {}
    trigger/Lambda? := null
    known-triggers.do: | key/string value/Lambda |
      is-map-trigger := map-triggers.contains key
      if is-map-trigger:
        if data is Map and has-key_ data key:
          seen-types.add key
          trigger = value
      else if data is string and data == key:
        seen-types.add key
        trigger = value
    if seen-types.size == 0:
      format-error_ "Unknown trigger in container $container-name: $data"
    if seen-types.size != 1:
      format-error_ "Container $container-name has ambiguous trigger: $data"

    return trigger.call data

class IntervalTrigger extends Trigger:
  interval/Duration

  constructor .interval:

  constructor.from-json container-name/string data/Map:
    holder := "trigger in container $container-name"
    interval = get-duration_ data "interval" --holder=holder

  type -> string:
    return "interval"

  json-value -> int:
    return interval.in-s

class BootTrigger extends Trigger:
  type -> string:
    return "boot"

  json-value -> int:
    return 1

class InstallTrigger extends Trigger:
  // We use a unique nonce for the install trigger, so
  // we can be sure that re-installing a container
  // causes a modification to the goal state.
  nonce_/string

  constructor:
    id := random-uuid --namespace="install nonce"
    nonce_ = base64.encode id.to-byte-array

  type -> string:
    return "install"

  json-value -> string:
    return nonce_

abstract class GpioTrigger extends Trigger:
  pin/int

  constructor .pin:

  static parse-json container-name/string data/Map -> List:
    holder := "container $container-name"
    gpio-trigger-list := get-list_ data "gpio" --holder=holder
    // Check that all entries are maps.
    gpio-trigger-list.do: | entry |
      if entry is not Map:
        format-error_ "Entry in gpio trigger list of $holder is not a map"

    pin-triggers := gpio-trigger-list.map: | entry/Map |
      pin-holder := "gpio trigger in container $container-name"
      pin := get-int_ entry "pin" --holder=pin-holder
      pin-holder = "gpio trigger for pin $pin in container $container-name"
      on-touch := get-optional-bool_ entry "touch" --holder=pin-holder
      level-string := get-optional-string_ entry "level" --holder=pin-holder
      on-high := ?
      if on-touch:
        if level-string != null:
          format-error_ "Both level $level-string and touch are set in $holder"
          unreachable
        on-high = null
      else:
        if level-string == "high" or level-string == null:
          on-high = true
        else if level-string == "low":
          on-high = false
        else:
          format-error_ "Invalid level in $holder: $level-string"
          unreachable

      if on-high: GpioTriggerHigh pin
      else if on-touch: GpioTriggerTouch pin
      else: GpioTriggerLow pin

    seen-pins := {}
    pin-triggers.do: | trigger/GpioTrigger |
      if seen-pins.contains trigger.pin:
        format-error_ "Duplicate pin in gpio trigger of $holder"
      seen-pins.add trigger.pin

    return pin-triggers

  type -> string:
    return "$pin-trigger-kind:$pin"

  json-value -> int:
    // Use the pin as value, so that the service doesn't need to decode it.
    return pin

  abstract pin-trigger-kind -> string

class GpioTriggerHigh extends GpioTrigger:
  constructor pin/int: super pin

  pin-trigger-kind -> string: return "gpio-high"

class GpioTriggerLow extends GpioTrigger:
  constructor pin/int: super pin

  pin-trigger-kind -> string: return "gpio-low"

class GpioTriggerTouch extends GpioTrigger:
  constructor pin/int: super pin

  pin-trigger-kind -> string: return "gpio-touch"
