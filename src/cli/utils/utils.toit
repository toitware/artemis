// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate_roots
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

write_json_to_file path/string value/any -> none:
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
  if response.status_code != 200:
    throw "Failed to download $url: $response.status_code $response.status_message"
  file := file.Stream.for_write out_path
  writer := writer.Writer file
  while chunk := response.body.read:
    writer.write chunk
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
    while chunk := in_stream.read:
      writer.write chunk
    // TODO(florian): we would like to close the writer here, but then
    // we would get an "already closed" below.
  finally:
    in_stream.close
    out_stream.close

random_uuid_string -> string:
  return (uuid.uuid5 "Device ID" "$Time.now $Time.monotonic_us $random").stringify

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
