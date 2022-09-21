// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ar
import binary show LITTLE_ENDIAN
import crypto.sha256
import uuid

import host.arguments
import host.directory
import host.file
import host.os
import host.pipe

import .client
import .mqtt.aws
import .postgrest.supabase

// TODO:
//  - groups of devices
//  - device reject of configuration

main args:
  parser := arguments.ArgumentParser
  parser.add_option "device" --short="d" --default=(pipe.backticks "hostname").trim
  parser.add_flag "supabase" --short="S"

  install_cmd := parser.add_command "install"
  install_cmd.describe_rest ["app-name", "snapshot-file"]

  uninstall_cmd := parser.add_command "uninstall"
  uninstall_cmd.describe_rest ["app-name"]

  update_cmd := parser.add_command "update"
  update_cmd.describe_rest ["firmware.bin"]

  set_max_offline_cmd := parser.add_command "set-max-offline"
  set_max_offline_cmd.describe_rest ["offline-time-in-seconds"]

  status_cmd := parser.add_command "status"

  watch_presence_cmd := parser.add_command "watch-presence"

  parsed/arguments.Arguments := parser.parse args
  client/Client? := null
  if parsed["supabase"]:
    client = ClientSupabase parsed["device"]
  else:
    client = ClientAws parsed["device"]

  if not run_cli client parsed:
    print_on_stderr_ (parser.usage args)
    exit 1

run_cli client/Client parsed/arguments.Arguments -> bool:
  if parsed.command == "install":
    client.update_config: | config/Map |
      install_app parsed config client
  else if parsed.command == "uninstall":
    client.update_config: | config/Map |
      uninstall_app parsed config
  else if parsed.command == "update":
    client.update_config: | config/Map |
      update_firmware parsed config client
  else if parsed.command == "set-max-offline":
    client.update_config: | config/Map |
      set_max_offline parsed config
  else if parsed.command == "status":
    client.print_status
  else if parsed.command == "watch-presence":
    client.watch_presence
  else:
    return false
  return true

install_app args/arguments.Arguments config/Map client/Client -> Map:
  app := args.rest[0]

  snapshot_path := args.rest[1]
  id := get_uuid_from_snapshot snapshot_path
  if not id:
    print_on_stderr_ "$snapshot_path: Not a valid Toit snapshot"
    exit 1

  // Create the two images.
  sdk := get_toit_sdk
  tmpdir := directory.mkdtemp "/tmp/artemis-snapshot-to-image-"
  image32 := "$tmpdir/image32"
  image64 := "$tmpdir/image64"

  try:
    pipe.run_program ["$sdk/tools/snapshot_to_image", "-m32", "--binary", "-o", image32, snapshot_path]
    pipe.run_program ["$sdk/tools/snapshot_to_image", "-m64", "--binary", "-o", image64, snapshot_path]
    client.upload_image id --bits=32 (file.read_content image32)
    client.upload_image id --bits=64 (file.read_content image64)
  finally:
    catch: file.delete image32
    catch: file.delete image64
    directory.rmdir tmpdir

  print "$(%08d Time.monotonic_us): Installing app: $app"
  apps := config.get "apps" --if_absent=: {:}
  apps[app] = {"id": id, "random": (random 1000)}
  config["apps"] = apps
  return config

uninstall_app args/arguments.Arguments config/Map -> Map:
  app := args.rest[0]
  print "$(%08d Time.monotonic_us): Uninstalling app: $app"
  apps := config.get "apps"
  if not apps: return config
  apps.remove app
  return config

update_firmware args/arguments.Arguments config/Map client/Client -> Map:
  firmware_path := args.rest[0]
  firmware_bin := file.read_content firmware_path
  sha := sha256.Sha256
  sha.add firmware_bin
  id/string := "$(uuid.Uuid sha.get[0..uuid.SIZE])"
  client.upload_firmware id firmware_bin
  config["firmware"] = id
  return config

set_max_offline args/arguments.Arguments config/Map -> Map:
  max_offline := int.parse args.rest[0]
  print "$(%08d Time.monotonic_us): Setting max-offline to $(Duration --s=max_offline)"
  if max_offline > 0:
    config["max-offline"] = max_offline
  else:
    config.remove "max-offline"
  return config

get_toit_sdk -> string:
  if os.env.contains "JAG_TOIT_REPO_PATH":
    repo := "$(os.env["JAG_TOIT_REPO_PATH"])/build/host/sdk"
    if file.is_directory "$repo/bin" and file.is_directory "$repo/tools":
      return repo
    print_on_stderr_ "JAG_TOIT_REPO_PATH doesn't point to a built Toit repo"
    exit 1
  if os.env.contains "HOME":
    jaguar := "$(os.env["HOME"])/.cache/jaguar/sdk"
    if file.is_directory "$jaguar/bin" and file.is_directory "$jaguar/tools":
      return jaguar
    print_on_stderr_ "\$HOME/.cache/jaguar/sdk doesn't contain a Toit SDK"
    exit 1
  print_on_stderr_ "Did not find JAG_TOIT_REPO_PATH or a Jaguar installation"
  exit 1
  unreachable

get_uuid_from_snapshot snapshot_path/string -> string?:
  if not file.is_file snapshot_path:
    print_on_stderr_ "$snapshot_path: Not a file"
    exit 1

  snapshot := file.read_content snapshot_path

  ar_reader /ar.ArReader? := null
  exception := catch:
    ar_reader = ar.ArReader.from_bytes snapshot  // Throws if it's not a snapshot.
  if exception: return null
  first := ar_reader.next
  if first.name != "toit": return null
  id/string? := null
  while member := ar_reader.next:
    if member.name == "uuid":
      id = (uuid.Uuid member.content).stringify
  return id
