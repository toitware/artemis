// Copyright (C) 2023 Toitware ApS. All rights reserved.

import bytes
import certificate_roots
import cli
import encoding.base64
import encoding.json
import encoding.ubjson
import encoding.tison
import http
import host.directory
import host.file
import host.os
import log
import net
import host.pipe
import writer
import uuid
import ..ui
import ..device_specification

with_tmp_directory [block]:
  tmpdir := directory.mkdtemp "/tmp/artemis-"
  try:
    block.call tmpdir
  finally:
    directory.rmdir --recursive tmpdir

write_blob_to_file path/string value -> none:
  stream := file.Stream.for_write path
  try:
    writer := writer.Writer stream
    writer.write value
  finally:
    stream.close

write_json_to_file path/string value/any --pretty/bool=false -> none:
  if pretty:
    write_blob_to_file path (json_encode_pretty value)
  else:
    write_blob_to_file path (json.encode value)

write_ubjson_to_file path/string value/any -> none:
  encoded := ubjson.encode value
  write_blob_to_file path encoded

write_base64_ubjson_to_file path/string value/any -> none:
  encoded := base64.encode (ubjson.encode value)
  write_blob_to_file path encoded

read_json path/string -> any:
  stream := file.Stream.for_read path
  try:
    return json.decode_stream stream
  finally:
    stream.close

read_ubjson path/string -> any:
  data := file.read_content path
  return ubjson.decode data

read_tison path/string -> any:
  data := file.read_content path
  return tison.decode data

read_base64_ubjson path/string -> any:
  data := file.read_content path
  return ubjson.decode (base64.decode data)

download_url url/string --out_path/string -> none:
  network := net.open
  client := http.Client.tls network
      --root_certificates=certificate_roots.ALL
  parts := url.split --at_first "/"
  host := parts.first
  path := parts.last
  log.info "Downloading $url"
  response := client.get host path
  if response.status_code != http.STATUS_OK:
    throw "Failed to download $url: $response.status_code $response.status_message"
  file := file.Stream.for_write out_path
  writer := writer.Writer file
  writer.write_from response.body
  writer.close
  // TODO(florian): closing should be idempotent.
  // file.close

tool_path_ tool/string -> string:
  if platform != PLATFORM_WINDOWS: return tool
  // On Windows, we use the <tool>.exe that comes with Git for Windows.

  // TODO(florian): depending on environment variables is brittle.
  // We should use `SearchPath` (to find `git.exe` in the PATH), or
  // 'SHGetSpecialFolderPath' (to find the default 'Program Files' folder).
  program_files_path := os.env.get "ProgramFiles"
  if not program_files_path:
    // This is brittle, as Windows localizes the name of the folder.
    program_files_path = "C:/Program Files"
  result := "$program_files_path/Git/usr/bin/$(tool).exe"
  if not file.is_file result:
    throw "Could not find $result. Please install Git for Windows"
  return result

/**
Copies the $source directory into the $target directory.

If the $target directory does not exist, it is created.
*/
copy_directory --source/string --target/string:
  directory.mkdir --recursive target
  with_tmp_directory: | tmp_dir |
    // We are using `tar` so we keep the permissions.
    tar := tool_path_ "tar"

    tmp_tar := "$tmp_dir/tmp.tar"
    extra_args := []
    if platform == PLATFORM_WINDOWS:
      // Tar can't handle backslashes as separators.
      source = source.replace --all "\\" "/"
      target = target.replace --all "\\" "/"
      tmp_tar = tmp_tar.replace --all "\\" "/"
      extra_args = ["--force-local"]

    // We are using an intermediate file.
    // Using pipes was too slow on Windows.
    // See https://github.com/toitlang/toit/issues/1568.
    pipe.backticks [tar, "c", "-f", tmp_tar, "-C", source, "."] + extra_args
    pipe.backticks [tar, "x", "-f", tmp_tar, "-C", target] + extra_args

/**
Untars the given $path into the $target directory.

Do not use this function on compressed tar files. That would work
  on Linux/macOS, but not on Windows.
*/
untar path/string --target/string:
  generic_arguments := [
    tool_path_ "tar",
    "x",  // Extract.
  ]

  if platform == PLATFORM_WINDOWS:
    // The target must use slashes as separators.
    // Otherwise Git's tar can't find the target directory.
    target = target.replace --all "\\" "/"
    // Treat 'c:\' as a local path.
    generic_arguments.add "--force-local"

  pipe.backticks generic_arguments + [
    "-f", path,    // The file at 'path'
    "-C", target,  // Extract to 'target'.
  ]

gunzip path/string:
  gzip_path := tool_path_ "gzip"
  pipe.backticks [
    gzip_path,
    "-d",
    path,
  ]

copy_file --source/string --target/string:
  in_stream := file.Stream.for_read source
  out_stream := file.Stream.for_write target
  try:
    writer := writer.Writer out_stream
    writer.write_from in_stream
    // TODO(florian): we would like to close the writer here, but then
    // we would get an "already closed" below.
  finally:
    in_stream.close
    out_stream.close

random_uuid --namespace/string="Artemis" -> uuid.Uuid:
  return uuid.uuid5 namespace "$Time.now $Time.monotonic_us $random"

json_encode_pretty value/any -> ByteArray:
  buffer := bytes.Buffer
  json_encode_pretty_ value buffer --indentation=0
  buffer.write "\n"
  buffer.close
  return buffer.buffer

// TODO(florian): move this into the core library.
json_encode_pretty_ value/any buffer/bytes.Buffer --indentation/int=0 -> none:
  indentation_string/string? := null
  newline := :
    buffer.write "\n"
    if not indentation_string: indentation_string = " " * indentation
    buffer.write indentation_string

  if value is List:
    list := value as List
    buffer.write "["
    if list.is_empty:
      buffer.write "]"
      return
    newline.call
    list.size.repeat: | i/int |
      element := list[i]
      buffer.write "  "
      json_encode_pretty_ element buffer --indentation=indentation + 2
      if i < list.size - 1: buffer.write ","
      newline.call
    buffer.write "]"
    return
  if value is Map:
    map := value as Map
    buffer.write "{"
    if map.is_empty:
      buffer.write "}"
      return
    newline.call
    size := map.size
    count := 0
    map.do: | key value |
      count++
      is_last := count == size
      buffer.write "  "
      buffer.write (json.encode key)
      buffer.write ": "
      json_encode_pretty_ value buffer --indentation=indentation + 2
      if not is_last: buffer.write ","
      newline.call
    buffer.write "}"
    return
  buffer.write (json.encode value)

/**
Parses the given $path into a DeviceSpecification.

If there is an error, calls $Ui.abort with an error message.
*/
parse_device_specification_file path/string --ui/Ui -> DeviceSpecification:
  exception := catch --unwind=(: it is not DeviceSpecificationException):
    return DeviceSpecification.parse path
  ui.abort "Error parsing device specification: $exception"
  unreachable

// TODO(florian): move this into Duration?
/**
Parses a string like "1h 30m 10s" or "1h30m10s" into a Duration.
*/
parse_duration str/string -> Duration:
  return parse_duration str --on_error=: throw "Invalid duration string: $it"

parse_duration str/string [--on_error] -> Duration:
  UNITS ::= ["h", "m", "s"]
  splits_with_missing := UNITS.map: str.index_of it
  splits := splits_with_missing.filter: it != -1
  if splits.is_empty or not splits.is_sorted:
    return on_error.call str
  if splits.last != str.size - 1:
    return on_error.call str

  last_unit := -1
  values := {:}
  splits.do: | split/int |
    unit := str[split]
    value_string := str[last_unit + 1..split]
    value := int.parse value_string.trim --on_error=:
      return on_error.call str
    values[unit] = value
    last_unit = split

  return Duration
      --h=values.get 'h' --if_absent=: 0
      --m=values.get 'm' --if_absent=: 0
      --s=values.get 's' --if_absent=: 0

/**
Converts a time object to a string.

Contrary to the built-in $TimeInfo.to_iso8601_string this
  function includes nano-seconds.
*/
timestamp_to_string timestamp/Time -> string:
  utc := timestamp.utc
  return """
    $(utc.year)-$(%02d utc.month)-$(%02d utc.day)-T\
    $(%02d utc.h):$(%02d utc.m):$(%02d utc.s).\
    $(%09d timestamp.ns_part)Z"""

timestamp_to_human_readable timestamp/Time --now_cut_off/Duration=(Duration --s=10) -> string:
  now := Time.now
  diff := timestamp.to now
  if diff < (Duration --s=10):
    return "now"
  if diff < (Duration --m=1):
    return "$diff.in_s seconds ago"
  if diff < (Duration --h=1):
    return "$diff.in_m minutes ago"
  local_now := Time.now.local
  local := timestamp.local
  if local_now.year == local.year and local_now.month == local.month and local_now.day == local.day:
    return "$(%02d local.h):$(%02d local.m):$(%02d local.s)"
  return "$local.year-$(%02d local.month)-$(%02d local.day) $(%02d local.h):$(%02d local.m):$(%02d local.s)"

// TODO(florian): move this into the cli package.
class OptionPatterns extends cli.OptionEnum:
  constructor name/string patterns/List
      --default=null
      --short_name/string?=null
      --short_help/string?=null
      --required/bool=false
      --hidden/bool=false
      --multi/bool=false
      --split_commas/bool=false:
    super name patterns
      --default=default
      --short_name=short_name
      --short_help=short_help
      --required=required
      --hidden=hidden
      --multi=multi
      --split_commas=split_commas

  parse str/string --for_help_example/bool=false -> any:
    if not str.contains ":" and not str.contains "=":
      // Make sure it's a valid one.
      key := super str --for_help_example=for_help_example
      return key

    separator_index := str.index_of ":"
    if separator_index < 0: separator_index = str.index_of "="
    key := str[..separator_index]
    key_with_equals := str[..separator_index + 1]
    if not (values.any: it.starts_with key_with_equals):
      throw "Invalid value for option '$name': '$str'. Valid values are: $(values.join ", ")."

    return {
      key: str[separator_index + 1..]
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
      --short_name/string?=null
      --short_help/string?=null
      --required/bool=false
      --hidden/bool=false
      --multi/bool=false
      --split_commas/bool=false:
    if multi and default: throw "Multi option can't have default value."
    if required and default: throw "Option can't have default value and be required."
    super.from_subclass name --short_name=short_name --short_help=short_help \
        --required=required --hidden=hidden --multi=multi \
        --split_commas=split_commas

  is_flag: return false

  type -> string: return "uuid"

  parse str/string --for_help_example/bool=false -> uuid.Uuid:
    catch: return uuid.parse str
    throw "Invalid value for option '$name': '$str'. Expected a UUID."


/** Whether we are running in a development setup. */
is_dev_setup -> bool:
  return program_name.ends_with ".toit"
