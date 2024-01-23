// Copyright (C) 2023 Toitware ApS. All rights reserved.

import bytes
import certificate-roots
import cli
import encoding.base64
import encoding.json
import encoding.ubjson
import encoding.tison
import http
import host.directory
import host.file
import host.os
import host.pipe
import log
import net
import system
import writer
import uuid
import ..ui
import ..pod-specification

with-tmp-directory [block]:
  tmpdir := directory.mkdtemp "/tmp/artemis-"
  try:
    block.call tmpdir
  finally:
    directory.rmdir --recursive tmpdir

write-blob-to-file path/string value -> none:
  stream := file.Stream.for-write path
  try:
    writer := writer.Writer stream
    writer.write value
  finally:
    stream.close

write-json-to-file path/string value/any --pretty/bool=false -> none:
  if pretty:
    write-blob-to-file path (json-encode-pretty value)
  else:
    write-blob-to-file path (json.encode value)

write-ubjson-to-file path/string value/any -> none:
  encoded := ubjson.encode value
  write-blob-to-file path encoded

write-base64-ubjson-to-file path/string value/any -> none:
  encoded := base64.encode (ubjson.encode value)
  write-blob-to-file path encoded

read-json path/string -> any:
  stream := file.Stream.for-read path
  try:
    return json.decode-stream stream
  finally:
    stream.close

read-ubjson path/string -> any:
  data := file.read-content path
  return ubjson.decode data

read-tison path/string -> any:
  data := file.read-content path
  return tison.decode data

read-base64-ubjson path/string -> any:
  data := file.read-content path
  return ubjson.decode (base64.decode data)

read-file path/string --ui/Ui [block] -> any:
  return read-file path block --on-error=: | exception |
    ui.abort "Failed to open '$path' for reading ($exception)."

read-file path/string [block] [--on-error] -> any:
  stream/file.Stream? := null
  exception := catch: stream = file.Stream.for-read path
  if not stream:
    return on-error.call exception
  try:
    return block.call stream
  finally:
    stream.close

write-file path/string --ui/Ui [block] -> none:
  write-file path block --on-error=: | exception |
    ui.abort "Failed to open '$path' for writing ($exception)."

write-file path/string [block] [--on-error] -> none:
  stream/file.Stream? := null
  exception := catch: stream = file.Stream.for-write path
  if not stream:
    on-error.call exception
    return
  try:
    writer := writer.Writer stream
    block.call writer
  finally:
    stream.close

download-url url/string --out-path/string -> none:
  log.info "Downloading $url."

  network := net.open
  try:
    client := http.Client.tls network
        --root-certificates=certificate-roots.ALL

    response := client.get --uri=url
    if response.status-code != http.STATUS-OK:
      log.error "Failed to download $url: $response.status-code $response.status-message."
      exit 1
    file := file.Stream.for-write out-path
    writer := writer.Writer file
    writer.write-from response.body
    writer.close
    // TODO(florian): closing should be idempotent.
    // file.close
  finally:
    network.close

tool-path_ tool/string -> string:
  if system.platform != system.PLATFORM-WINDOWS: return tool
  // On Windows, we use the <tool>.exe that comes with Git for Windows.

  // TODO(florian): depending on environment variables is brittle.
  // We should use `SearchPath` (to find `git.exe` in the PATH), or
  // 'SHGetSpecialFolderPath' (to find the default 'Program Files' folder).
  program-files-path := os.env.get "ProgramFiles"
  if not program-files-path:
    // This is brittle, as Windows localizes the name of the folder.
    program-files-path = "C:/Program Files"
  result := "$program-files-path/Git/usr/bin/$(tool).exe"
  if not file.is-file result:
    throw "Could not find $result. Please install Git for Windows"
  return result

/**
Copies the $source directory into the $target directory.

If the $target directory does not exist, it is created.
*/
copy-directory --source/string --target/string:
  directory.mkdir --recursive target
  with-tmp-directory: | tmp-dir |
    // We are using `tar` so we keep the permissions.
    tar := tool-path_ "tar"

    tmp-tar := "$tmp-dir/tmp.tar"
    extra-args := []
    if system.platform == system.PLATFORM-WINDOWS:
      // Tar can't handle backslashes as separators.
      source = source.replace --all "\\" "/"
      target = target.replace --all "\\" "/"
      tmp-tar = tmp-tar.replace --all "\\" "/"
      extra-args = ["--force-local"]

    // We are using an intermediate file.
    // Using pipes was too slow on Windows.
    // See https://github.com/toitlang/toit/issues/1568.
    pipe.backticks [tar, "c", "-f", tmp-tar, "-C", source, "."] + extra-args
    pipe.backticks [tar, "x", "-f", tmp-tar, "-C", target] + extra-args

/**
Untars the given $path into the $target directory.

Do not use this function on compressed tar files. That would work
  on Linux/macOS, but not on Windows.
*/
untar path/string --target/string:
  generic-arguments := [
    tool-path_ "tar",
    "x",  // Extract.
  ]

  if system.platform == system.PLATFORM-WINDOWS:
    // The target must use slashes as separators.
    // Otherwise Git's tar can't find the target directory.
    target = target.replace --all "\\" "/"
    // Treat 'c:\' as a local path.
    generic-arguments.add "--force-local"

  pipe.backticks generic-arguments + [
    "-f", path,    // The file at 'path'
    "-C", target,  // Extract to 'target'.
  ]

gunzip path/string:
  gzip-path := tool-path_ "gzip"
  pipe.backticks [
    gzip-path,
    "-d",
    path,
  ]

copy-file --source/string --target/string:
  in-stream := file.Stream.for-read source
  out-stream := file.Stream.for-write target
  try:
    writer := writer.Writer out-stream
    writer.write-from in-stream
    // TODO(florian): we would like to close the writer here, but then
    // we would get an "already closed" below.
  finally:
    in-stream.close
    out-stream.close

random-uuid --namespace/string="Artemis" -> uuid.Uuid:
  return uuid.uuid5 namespace "$Time.now $Time.monotonic-us $random"

json-encode-pretty value/any -> ByteArray:
  buffer := bytes.Buffer
  json-encode-pretty_ value buffer --indentation=0
  buffer.write "\n"
  buffer.close
  return buffer.buffer

// TODO(florian): move this into the core library.
json-encode-pretty_ value/any buffer/bytes.Buffer --indentation/int=0 -> none:
  indentation-string/string? := null
  newline := :
    buffer.write "\n"
    if not indentation-string: indentation-string = " " * indentation
    buffer.write indentation-string

  if value is List:
    list := value as List
    buffer.write "["
    if list.is-empty:
      buffer.write "]"
      return
    newline.call
    list.size.repeat: | i/int |
      element := list[i]
      buffer.write "  "
      json-encode-pretty_ element buffer --indentation=indentation + 2
      if i < list.size - 1: buffer.write ","
      newline.call
    buffer.write "]"
    return
  if value is Map:
    map := value as Map
    buffer.write "{"
    if map.is-empty:
      buffer.write "}"
      return
    newline.call
    size := map.size
    count := 0
    map.do: | key value |
      count++
      is-last := count == size
      buffer.write "  "
      buffer.write (json.encode key)
      buffer.write ": "
      json-encode-pretty_ value buffer --indentation=indentation + 2
      if not is-last: buffer.write ","
      newline.call
    buffer.write "}"
    return
  buffer.write (json.encode value)

/**
Parses the given $path into a $PodSpecification.

If there is an error, calls $Ui.abort with an error message.
*/
parse-pod-specification-file path/string --ui/Ui -> PodSpecification:
  exception := catch --unwind=(: it is not PodSpecificationException):
    return PodSpecification.parse path
  ui.abort "Cannot parse pod specification: $exception."
  unreachable

// TODO(florian): move this into Duration?
/**
Parses a string like "1h 30m 10s" or "1h30m10s" into a Duration.
*/
parse-duration str/string -> Duration:
  return parse-duration str --on-error=: throw "Invalid duration string: $it"

parse-duration str/string [--on-error] -> Duration:
  UNITS ::= ["h", "m", "s"]
  splits-with-missing := UNITS.map: str.index-of it
  splits := splits-with-missing.filter: it != -1
  if splits.is-empty or not splits.is-sorted:
    return on-error.call str
  if splits.last != str.size - 1:
    return on-error.call str

  last-unit := -1
  values := {:}
  splits.do: | split/int |
    unit := str[split]
    value-string := str[last-unit + 1..split]
    value := int.parse value-string.trim --on-error=:
      return on-error.call str
    values[unit] = value
    last-unit = split

  return Duration
      --h=values.get 'h' --if-absent=: 0
      --m=values.get 'm' --if-absent=: 0
      --s=values.get 's' --if-absent=: 0

/**
Converts a time object to a string.

Contrary to the built-in $TimeInfo.to-iso8601-string this
  function includes nano-seconds.
*/
timestamp-to-string timestamp/Time -> string:
  utc := timestamp.utc
  return """
    $(utc.year)-$(%02d utc.month)-$(%02d utc.day)-T\
    $(%02d utc.h):$(%02d utc.m):$(%02d utc.s).\
    $(%09d timestamp.ns-part)Z"""

timestamp-to-human-readable timestamp/Time --now-cut-off/Duration=(Duration --s=10) -> string:
  now := Time.now
  diff := timestamp.to now
  if diff < (Duration --s=10):
    return "now"
  if diff < (Duration --m=1):
    return "$diff.in-s seconds ago"
  if diff < (Duration --h=1):
    return "$diff.in-m minutes ago"
  local-now := Time.now.local
  local := timestamp.local
  if local-now.year == local.year and local-now.month == local.month and local-now.day == local.day:
    return "$(%02d local.h):$(%02d local.m):$(%02d local.s)"
  return "$local.year-$(%02d local.month)-$(%02d local.day) $(%02d local.h):$(%02d local.m):$(%02d local.s)"

// TODO(florian): move this into the cli package.
class OptionPatterns extends cli.OptionEnum:
  constructor name/string patterns/List
      --default=null
      --short-name/string?=null
      --help/string?=null
      --required/bool=false
      --hidden/bool=false
      --multi/bool=false
      --split-commas/bool=false:
    super name patterns
      --default=default
      --short-name=short-name
      --help=help
      --required=required
      --hidden=hidden
      --multi=multi
      --split-commas=split-commas

  parse str/string --for-help-example/bool=false -> any:
    if not str.contains ":" and not str.contains "=":
      // Make sure it's a valid one.
      key := super str --for-help-example=for-help-example
      return key

    separator-index := str.index-of ":"
    if separator-index < 0: separator-index = str.index-of "="
    key := str[..separator-index]
    key-with-equals := str[..separator-index + 1]
    if not (values.any: it.starts-with key-with-equals):
      throw "Invalid value for option '$name': '$str'. Valid values are: $(values.join ", ")."

    return {
      key: str[separator-index + 1..]
    }

/**
A Uuid option.
*/
class OptionUuid extends cli.Option:
  default/uuid.Uuid?

  /**
  Creates a new Uuid option.

  The $default value is null.

  The $type is set to 'uuid'.

  Ensures that values are valid Uuids.
  */
  constructor name/string
      --.default=null
      --short-name/string?=null
      --help/string?=null
      --required/bool=false
      --hidden/bool=false
      --multi/bool=false
      --split-commas/bool=false:
    if multi and default: throw "Multi option can't have default value."
    if required and default: throw "Option can't have default value and be required."
    super.from-subclass name --short-name=short-name --help=help \
        --required=required --hidden=hidden --multi=multi \
        --split-commas=split-commas

  is-flag: return false

  type -> string: return "uuid"

  parse str/string --for-help-example/bool=false -> uuid.Uuid:
    catch: return uuid.parse str
    throw "Invalid value for option '$name': '$str'. Expected a UUID."


/** Whether we are running in a development setup. */
is-dev-setup -> bool:
  return system.program-name.ends-with ".toit"
