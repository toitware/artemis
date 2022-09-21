// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ar
import crypto.sha256
import host.file
import host.directory
import host.pipe
import host.os
import uuid

import .client

class Artemis:
  app_install client/Client --app_name/string --snapshot_path/string:
    id := get_uuid_from_snapshot snapshot_path
    if not id:
      print_on_stderr_ "$snapshot_path: Not a valid Toit snapshot"
      exit 1

    // Create the two images.
    sdk := get_toit_sdk
    tmpdir := directory.mkdtemp "/tmp/artemis-snapshot-to-image-"
    image32 := "$tmpdir/image32"
    image64 := "$tmpdir/image64"

    client.update_config: | config/Map |
      // We have to start updating the config already here, as the call to
      // client.upload_image requires a running MQTT connection.
      try:
        pipe.run_program ["$sdk/tools/snapshot_to_image", "-m32", "--binary", "-o", image32, snapshot_path]
        pipe.run_program ["$sdk/tools/snapshot_to_image", "-m64", "--binary", "-o", image64, snapshot_path]
        client.upload_image id --bits=32 (file.read_content image32)
        client.upload_image id --bits=64 (file.read_content image64)
      finally:
        catch: file.delete image32
        catch: file.delete image64
        directory.rmdir tmpdir

      print "$(%08d Time.monotonic_us): Installing app: $app_name"
      apps := config.get "apps" --if_absent=: {:}
      apps[app_name] = {"id": id, "random": (random 1000)}
      config["apps"] = apps
      config

  app_uninstall client/Client --app_name/string:
    client.update_config: | config/Map |
      print "$(%08d Time.monotonic_us): Uninstalling app: $app_name"
      apps := config.get "apps"
      if apps: apps.remove app_name
      config

  config_set_max_offline client/Client --max_offline_seconds/int:
    client.update_config: | config/Map |
      print "$(%08d Time.monotonic_us): Setting max-offline to $(Duration --s=max_offline_seconds)"
      if max_offline_seconds > 0:
        config["max-offline"] = max_offline_seconds
      else:
        config.remove "max-offline"
      config

  firmware_update client/Client --firmware_path/string:
    firmware_bin := file.read_content firmware_path
    sha := sha256.Sha256
    sha.add firmware_bin
    id/string := "$(uuid.Uuid sha.get[0..uuid.SIZE])"

    client.update_config: | config/Map |
      client.upload_firmware id firmware_bin
      config["firmware"] = id
      config

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
