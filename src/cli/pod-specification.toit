// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show Cli DirectoryStore
import encoding.base64
import encoding.url as url-encoding
import host.directory
import host.file
import fs
import semver

import .cache as cli
import .cache show cache-key-git-app
import .firmware
import .sdk
import .server-config
import .utils
import .git

import ..shared.version show SDK-VERSION ARTEMIS-VERSION

JSON-SCHEMA ::= "https://toit.io/schemas/artemis/pod-specification/v1.json"

INITIAL-POD-NAME ::= "my-pod"
INITIAL-POD-SPECIFICATION -> Map:
  return {
    "\$schema": JSON-SCHEMA,
    "sdk-version": SDK-VERSION,
    "artemis-version": ARTEMIS-VERSION,
    "max-offline": "5m",
    "firmware-envelope": "esp32",
    "partitions": "esp32-ota-1c0000",
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
    "\$schema": JSON-SCHEMA,
    "name": "example-pod",
    "sdk-version": SDK-VERSION,
    "artemis-version": ARTEMIS-VERSION,
    "max-offline": "12h",
    "firmware-envelope": "esp32",
    "partitions": "esp32-ota-1c0000",
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

read-pod-spec-file path/string -> any:
  if path.ends-with ".json":
    return read-json path
  if path.ends-with ".yaml" or path.ends-with ".yml":
    return read-yaml path
  throw "Unknown file extension: $path"

// We use `map.get` so that specifications can "delete" entries they have
// included by overriding them with 'null'.
has-key_ map/Map key/string -> bool:
  return (map.get key) != null

class JsonMap:
  map/Map
  holder/string
  cli/Cli

  used/Set := {}

  constructor .map --.holder --.cli --used/Set?=null:
    // Allow to share the "used" set.
    if used: this.used = used

  check-has-key key/string:
    if not has-key_ map key:
      format-error_ "Missing $key in $holder."

  has-key key/string -> bool:
    return has-key_ map key

  check-is-map key/string --entry-type/string="Entry":
    get-map key --entry-type=entry-type

  get-int key/string --entry-type/string="Entry" -> int:
    value := this[key]
    if value is not int:
      format-error_ "$entry-type $key in $holder is not an int: $value"
    return value

  get-string key/string --entry-type/string="Entry" -> string:
    value := this[key]
    if value is not string:
      format-error_ "$entry-type $key in $holder is not a string: $value"
    return value

  get-optional-int key/string --entry-type/string="Entry" -> int?:
    if not has-key key: return null
    return get-int key --entry-type=entry-type

  get-optional-string key/string --entry-type/string="Entry" -> string?:
    if not has-key key: return null
    return get-string key --entry-type=entry-type

  get-optional-list key/string --type/string [--check] --entry-type/string="Entry" -> List?:
    if not has-key key: return null
    value := this[key]
    if value is not List:
      format-error_ "$entry-type $key in $holder is not a list: $value"
    value.do:
      if not check.call it:
        format-error_ "$entry-type $key in $holder is not a list of $(type)s: $value"
    return value

  get-map key/string --entry-type/string="Entry" -> Map:
    value := this[key]
    if value is not Map:
      format-error_ "$entry-type $key in $holder is not a map: $value"
    return value

  get-optional-map key/string --entry-type/string="Entry" -> Map?:
    if not has-key key: return null
    return get-map key --entry-type=entry-type

  get-list key/string --entry-type/string="Entry" -> List:
    value := this[key]
    if value is not List:
      format-error_ "$entry-type $key in $holder is not a list: $value"
    return value

  get-optional-list key/string --entry-type/string="Entry" -> List?:
    if not has-key key: return null
    return get-list key --entry-type=entry-type

  /**
  Parses a string like "1h 30m 10s" or "1h30m10s" into seconds.
  Returns 0 if the string is empty.
  */
  get-duration key/string --entry-type/string="Entry" -> Duration:
    entry := this[key]
    if entry is not string:
      format-error_ "$entry-type $key in $holder is not a string: $entry"

    entry-string := entry as string
    entry-string = entry-string.trim
    if entry-string == "": return Duration.ZERO

    return parse-duration entry-string --on-error=:
      format-error_ "$entry-type $key in $holder is not a valid duration: $entry"

  get-optional-duration key/string --entry-type/string="Entry" -> Duration?:
    if not has-key key: return null
    return get-duration key --entry-type=entry-type

  get-optional-bool key/string --entry-type/string="Entry" -> bool?:
    if not has-key key: return null
    return get-bool key --entry-type=entry-type

  get-bool key/string --entry-type/string="Entry" -> bool:
    value := this[key]
    if value is not bool:
      format-error_ "$entry-type $key in $holder is not a boolean: $value"
    return value

  operator [] key/string -> any:
    check-has-key key
    used.add key
    return map[key]

  with-holder new-holder/string -> JsonMap:
    return JsonMap map --holder=new-holder --cli=cli --used=used

  warn-unused -> none:
    unused := []
    map.do --keys:
      if not used.contains it:
        cli.ui.emit --warning "Unused entry in $holder: $it"

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
  envelope/string
  partition-table/string?
  artemis-version/string
  max-offline-seconds/int
  connections/List  // Of $ConnectionInfo.
  containers/Map  // Of name -> $Container.
  path/string

  constructor.from-json --.path/string data/Map --cli/Cli:
    ui := cli.ui

    json-map := JsonMap data --holder="pod specification" --cli=cli
    name = json-map.get-string "name"
    artemis-version = json-map.get-string "artemis-version"
    sdk-version = json-map.get-optional-string "sdk-version"
    json-envelope := json-map.get-optional-string "firmware-envelope"

    if sdk-version and not semver.is-valid sdk-version:
      format-error_ "Invalid sdk-version: $sdk-version"

    if not sdk-version:
      ui.emit --warning "Implicit 'sdk-version' is deprecated. Please specify 'sdk-version'."

    chip := json-map.get-optional-string "chip"
    if not json-envelope and not chip:
      ui.emit --warning "Implicit envelope 'esp32' is deprecated. Please specify 'firmware-envelope'."
      json-envelope = "esp32"
    else if not json-envelope and chip:
      ui.emit --warning "The 'chip' property is deprecated. Use 'firmware-envelope' instead."
      json-envelope = chip
    else if json-envelope and chip:
      ui.emit --warning "The 'chip' property is deprecated and ignored. Only 'firmware-envelope' is used."

    envelope = json-envelope

    partition-table = json-map.get-optional-string "partitions"

    if json-map.has-key "apps" and json-map.has-key "containers":
      format-error_ "Both 'apps' and 'containers' are present in pod specification."

    version := json-map.get-optional-int "version"
    schema := json-map.get-optional-string "\$schema"
    if not version and not schema:
      // This will yield an error since the entry isn't present.
      json-map.get-string "\$schema"
    if schema:
      if schema != JSON-SCHEMA:
        format-error_ "Unsupported pod specification schema: $schema"
    else:
      if version != 1:
        // TODO(florian): recommend to upgrade to a '$schema' entry.
        format-error_ "Unsupported pod specification version $version"

    if json-map.has-key "apps" and not json-map.has-key "containers":
      json-map.check-is-map "apps"
      copy := json-map.map.copy
      copy["containers"] = json-map.map["apps"]
      copy.remove "apps"
      json-map = JsonMap copy --holder="pod specification" --cli=cli --used=json-map.used
    else if json-map.has-key "containers":
      json-map.check-is-map "containers"

    containers-entry := json-map.get-optional-map "containers"
    if not containers-entry: containers-entry = {:}

    containers-entry.do: | name/string value |
      if value is not Map:
        format-error_ "Container $name in pod specification is not a map: $value"

    containers = containers-entry.map: | name container-description |
      json-container-description := JsonMap container-description --holder="container $name" --cli=cli
      container := Container.from-json name json-container-description
      json-container-description.warn-unused
      container

    connections-entry := json-map.get-optional-list "connections"
    if not connections-entry: connections-entry = []
    connections-entry.do:
      if it is not Map:
        format-error_ "Connection in pod specification is not a map: $it"

    connections = connections-entry.map:
      json-connection-info := JsonMap it --holder="connection" --cli=cli
      connection := ConnectionInfo.from-json json-connection-info
      json-connection-info.warn-unused
      connection

    max-offline := json-map.get-optional-duration "max-offline"
    max-offline-seconds = max-offline ? max-offline.in-s : 0

    json-map.warn-unused
    validate_

  static parse path/string --cli/Cli -> PodSpecification:
    json := parse-json-hierarchy path
    if not json.contains "name":
      // Extract the name from the path.
      basename := fs.basename path
      dot-index := basename.index-of --last "."
      if dot-index >= 0:
        basename = basename[..dot-index]
      if basename != "":
        json["name"] = basename
    return PodSpecification.from-json --path=path json --cli=cli

  static parse-json-hierarchy path/string --extends-chain/List=[] -> Map:
    path = fs.clean path

    fail := : | error-message/string |
      extends-chain.do --reversed: | include-path/string |
        error-message += "\n  - Extended by $include-path."
      format-error_ error-message

    json := null
    exception := catch:
      json = read-pod-spec-file path
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
            validation-error_ "Connection requires container '$required-container-name', but it is not installed."

interface ConnectionInfo:
  static from-json json-map/JsonMap -> ConnectionInfo:
    type := json-map.get-string "type"
    if type == "wifi":
      return WifiConnectionInfo.from-json (json-map.with-holder "wifi connection")
    if type == "cellular":
      return CellularConnectionInfo.from-json (json-map.with-holder "cellular connection")
    if type == "ethernet":
      return EthernetConnectionInfo.from-json (json-map.with-holder "ethernet connection")
    format-error_ "Unknown connection type: $type"
    unreachable

  type -> string
  requires -> List?  // Of container names.
  to-json -> Map

class WifiConnectionInfo implements ConnectionInfo:
  ssid/string?
  password/string?

  constructor.from-json json-map/JsonMap:
    config := json-map.get-optional-string "config"
    if config:
      if config != "provisioned": format-error_ "Unknown wifi config: $config"
      ssid = null
      password = null
    else:
      ssid = json-map.get-string "ssid"
      password = json-map.get-string "password"

  type -> string:
    return "wifi"

  to-json -> Map:
    return {"type": type, "ssid": ssid, "password": password}

  requires -> List?:
    return null

class CellularConnectionInfo implements ConnectionInfo:
  config/Map?
  requires/List?

  constructor.from-json json-map/JsonMap:
    config = json-map.get-optional-map "config"
    requires = json-map.get-optional-list "requires"
        --type="string"
        --check=: it is string

  type -> string:
    return "cellular"

  to-json -> Map:
    result := {
      "type": type,
    }
    if config: result["config"] = config
    if requires: result["requires"] = requires
    return result

class EthernetConnectionInfo implements ConnectionInfo:
  requires/List?

  constructor.from-json json-map/JsonMap:
    requires = json-map.get-optional-list "requires"
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

  static from-json name/string json-map/JsonMap -> Container:
    if json-map.has-key "entrypoint" and json-map.has-key "snapshot":
      format-error_ "Container $name has both entrypoint and snapshot."

    if json-map.has-key "entrypoint":
      return ContainerPath.from-json name json-map
    if json-map.has-key "snapshot":
      return ContainerSnapshot.from-json name json-map

    format-error_ "Unsupported container $name: $json-map.map"
    unreachable

  /**
  Builds a snapshot and stores it at the given $output-path.

  All paths in the container are relative to $relative-to.
  */
  build-snapshot --output-path/string --relative-to/string --sdk/Sdk --cli/Cli -> none
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

  constructor.from-json .name json-map/JsonMap:
    arguments = json-map.get-optional-list "arguments"
        --type="string"
        --check=: it is string
    is-background = json-map.get-optional-bool "background"
    is-critical = json-map.get-optional-bool "critical"

    runlevel-key := "runlevel"
    if json-map.has-key runlevel-key:
      value := json-map[runlevel-key]
      if value is int:
        if value <= 0: format_error_ "Entry $runlevel-key in $json-map.holder must be positive"
        runlevel = value
      else if value is string:
        runlevel = Container.STRING-TO-RUNLEVEL_.get value
            --if-absent=: format-error_ "Unknown $runlevel-key in $json-map.holder: $value"
      else:
        format-error_ "Entry $runlevel-key in $json-map.holder is not an int or a string: $value"
        unreachable
    else:
      runlevel = null

    triggers-list := json-map.get-optional-list "triggers"
        --type="map or string"
        --check=: it is Map or it is string
    if triggers-list:
      if is-critical:
        format-error_ "Critical container $name cannot have triggers"
      triggers = []
      parsed-triggers := triggers-list.map: Trigger.parse-json name it --cli=json-map.cli
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

    defines = json-map.get-optional-map "defines"

  abstract type -> string
  abstract build-snapshot --output-path/string --relative-to/string --sdk/Sdk --cli/Cli -> none

class ContainerPath extends ContainerBase:
  entrypoint/string
  git-url/string?
  git-ref/string?
  compile-flags/List?

  constructor.from-json name/string json-map/JsonMap:
    holder := "container $name"
    git-ref = json-map.get-optional-string "branch"
    git-url = json-map.get-optional-string "git"
    entrypoint = json-map.get-string "entrypoint"
    compile-flags = json-map.get-optional-list "compile-flags"
        --type="string"
        --check=: it is string
    if git-url and not git-ref:
      format-error_ "In container $name, git entry requires a branch/tag: $git-url"
    if git-url and not fs.is-relative entrypoint:
      format-error_"In container $name, git entry requires a relative path: $entrypoint"
    super.from-json name json-map

  build-snapshot --output-path/string --relative-to/string --sdk/Sdk --cli/Cli -> none:
    ui := cli.ui

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

    git := Git --cli=cli
    cache-key := cache-key-git-app --url=git-url
    ui.emit --info "Fetching '$git-url'."
    cached-git := cli.cache.get-directory-path cache-key: | store/DirectoryStore |
      store.with-tmp-directory: | tmp-dir/string |
        clone-dir := "$tmp-dir/checkout"
        directory.mkdir clone-dir
        git.init clone-dir --origin=git-url --quiet
        git.config --repository-root=clone-dir
            --key="advice.detachedHead"
            --value="false"
        git.fetch
            --repository-root=clone-dir
            --depth=1
            --ref=git-ref
            --quiet
        // Write the url, so it's easier to understand what is in there.
        file.write-contents --path="$tmp-dir/URL" git-url
        store.move tmp-dir
    cached-checkout := "$cached-git/checkout"

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
      ui.emit --info "Compiling '$git-url'."
      entrypoint-path := "$clone-dir/$entrypoint"
      if not file.is-file entrypoint-path:
        ui.abort "Entry point '$entrypoint-path' does not exist."

      package-yaml-path := "$clone-dir/package.yaml"
      if not file.is-file package-yaml-path:
        if file.is-directory package-yaml-path:
          ui.abort "package.yaml is a directory in '$git-url'."
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
      if exception: ui.abort "Compilation of container '$name' failed: $exception."

  type -> string:
    return "path"

class ContainerSnapshot extends ContainerBase:
  snapshot-path/string

  constructor.from-json name/string json-map/JsonMap:
    snapshot-path = json-map.get-string "snapshot"
    super.from-json name json-map

  build-snapshot --relative-to/string --output-path/string --sdk/Sdk --cli/Cli -> none:
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
  static parse-json container-name/string data/any --cli/Cli -> any:
    known-triggers := {
      "boot": :: BootTrigger,
      "install": :: InstallTrigger,
      "interval": ::
        interval-map := JsonMap data --holder="trigger in container $container-name" --cli=cli
        trigger := IntervalTrigger.from-json interval-map
        interval-map.warn-unused
        trigger,
      "gpio": ::
        gpio-map := JsonMap data --holder="container $container-name" --cli=cli
        trigger := GpioTrigger.parse-json container-name gpio-map
        gpio-map.warn-unused
        trigger,
    }
    map-triggers := { "interval", "gpio" }

    seen-types := {}
    trigger-builder/Lambda? := null
    known-triggers.do: | key/string value/Lambda |
      is-map-trigger := map-triggers.contains key
      if is-map-trigger:
        if data is Map and has-key_ data key:
          seen-types.add key
          trigger-builder = value
      else if data is string and data == key:
        seen-types.add key
        trigger-builder = value
    if seen-types.size == 0:
      format-error_ "Unknown trigger in container $container-name: $data"
    if seen-types.size != 1:
      format-error_ "Container $container-name has ambiguous trigger: $data"

    return trigger-builder.call data

class IntervalTrigger extends Trigger:
  interval/Duration

  constructor .interval:

  constructor.from-json json-map/JsonMap:
    interval = json-map.get-duration "interval"

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

  static parse-json container-name/string json-map/JsonMap -> List:
    gpio-trigger-list := json-map.get-list "gpio"
    // Check that all entries are maps.
    gpio-trigger-list.do: | entry |
      if entry is not Map:
        format-error_ "Entry in gpio trigger list of $json-map.holder is not a map"

    pin-triggers := gpio-trigger-list.map: | entry/Map |
      pin-json-map := JsonMap entry --holder="gpio trigger in container $container-name" --cli=json-map.cli
      pin := pin-json-map.get-int "pin"
      pin-json-map = pin-json-map.with-holder "gpio trigger for pin $pin in container $container-name"
      on-touch := pin-json-map.get-optional-bool "touch"
      level-string := pin-json-map.get-optional-string "level"
      on-high := ?
      if on-touch:
        if level-string != null:
          format-error_ "Both level $level-string and touch are set in $pin-json-map.holder"
          unreachable
        on-high = null
      else:
        if level-string == "high" or level-string == null:
          on-high = true
        else if level-string == "low":
          on-high = false
        else:
          format-error_ "Invalid level in $pin-json-map.holder: $level-string"
          unreachable

      pin-json-map.warn-unused
      if on-high: GpioTriggerHigh pin
      else if on-touch: GpioTriggerTouch pin
      else: GpioTriggerLow pin

    seen-pins := {}
    pin-triggers.do: | trigger/GpioTrigger |
      if seen-pins.contains trigger.pin:
        format-error_ "Duplicate pin in gpio trigger of $json-map.holder"
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
