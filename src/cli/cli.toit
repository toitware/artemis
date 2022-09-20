// Copyright (C) 2022 Toitware ApS. All rights reserved.

import binary show LITTLE_ENDIAN
import encoding.json
import encoding.ubjson
import monitor
import mqtt
import net
import uuid
import crypto.sha256
import http

import host.arguments
import host.directory
import host.file
import host.os
import host.pipe

import ar

import ..shared.mqtt.aws
import ..shared.postgrest.supabase

CLIENT_ID ::= "toit/artemis-client-$(random 0x3fff_ffff)"

// TODO:
//  - groups of devices
//  - device reject of configuration

main args:
  parser := arguments.ArgumentParser
  parser.add_option "device" --short="d" --default="fisk"
  parser.add_flag "supabase" --short="S"

  install_cmd := parser.add_command "install"
  install_cmd.describe_rest ["app-name", "snapshot-file"]

  uninstall_cmd := parser.add_command "uninstall"
  uninstall_cmd.describe_rest ["app-name"]

  update_cmd := parser.add_command "update"
  install_cmd.describe_rest ["firmware.bin"]

  set_max_offline_cmd := parser.add_command "set-max-offline"
  set_max_offline_cmd.describe_rest ["offline-time-in-seconds"]

  status_cmd := parser.add_command "status"

  watch_presence_cmd := parser.add_command "watch-presence"

  parsed/arguments.Arguments := parser.parse args

  if parsed["supabase"]:
    device ::= DevicePostgrest parsed["device"]
    if parsed.command == "install":
      update_postgrest_config device: | config/Map client/http.Client |
        install_app parsed config client
    else if parsed.command == "uninstall":
      update_postgrest_config device: | config/Map |
        uninstall_app parsed config
    else if parsed.command == "update":
      update_postgrest_config device: | config/Map client/http.Client |
        update_firmware parsed config client
    else if parsed.command == "set-max-offline":
      update_postgrest_config device: | config/Map |
        set_max_offline parsed config
    else if parsed.command == "status":
      throw "Unimplemented command: $parsed.command --supabase"
    else if parsed.command == "watch-presence":
      throw "Unimplemented command: $parsed.command --supabase"
    else:
      print_on_stderr_
          parser.usage args
      exit 1
  else:
    device ::= DeviceMqtt parsed["device"]
    if parsed.command == "install":
      update_config device: | config/Map client/mqtt.Client |
        install_app parsed config client
    else if parsed.command == "uninstall":
      update_config device: | config/Map |
        uninstall_app parsed config
    else if parsed.command == "update":
      update_config device: | config/Map client/mqtt.Client |
        update_firmware parsed config client
    else if parsed.command == "set-max-offline":
      update_config device: | config/Map |
        set_max_offline parsed config
    else if parsed.command == "status":
      print_status device
    else if parsed.command == "watch-presence":
      watch_presence
    else:
      print_on_stderr_
          parser.usage args
      exit 1

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

install_app args/arguments.Arguments config/Map client -> Map:
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

    if client is mqtt.Client:
      client.publish "toit/apps/$id/image32" (file.read_content image32) --qos=1 --retain
      client.publish "toit/apps/$id/image64" (file.read_content image64) --qos=1 --retain
    else:
      upload_supabase client "images/$id.32" (file.read_content image32)
      upload_supabase client "images/$id.64" (file.read_content image64)
  finally:
    catch: file.delete image32
    catch: file.delete image64
    directory.rmdir tmpdir

  print "$(%08d Time.monotonic_us): Installing app: $app"
  apps := config.get "apps" --if_absent=: {:}
  apps[app] = {"id": id, "random": (random 1000)}
  config["apps"] = apps
  return config

upload_supabase client/http.Client path/string payload/ByteArray:
  headers := create_headers // <--- argh.
  headers.add "Content-Type" "application/octet-stream"
  headers.add "x-upsert" "true"
  response := client.post payload
      --host=SUPABASE_HOST
      --headers=headers
      --path="/storage/v1/object/$path"
  // 200 is accepted!
  if response.status_code != 200: throw "UGH ($response.status_code)"

uninstall_app args/arguments.Arguments config/Map -> Map:
  app := args.rest[0]
  print "$(%08d Time.monotonic_us): Uninstalling app: $app"
  apps := config.get "apps"
  if not apps: return config
  apps.remove app
  return config

update_firmware args/arguments.Arguments config/Map client -> Map:
  FIRMWARE_PART_SIZE ::= 64 * 1024

  firmware_path := args.rest[0]
  firmware_bin := file.read_content firmware_path
  sha := sha256.Sha256
  sha.add firmware_bin
  id/string := "$(uuid.Uuid sha.get[0..uuid.SIZE])"

  if client is mqtt.Client:
    cursor := 0
    parts := []
    while cursor < firmware_bin.size:
      end := min firmware_bin.size (cursor + FIRMWARE_PART_SIZE)
      parts.add cursor
      client.publish "toit/firmware/$id/$cursor" firmware_bin[cursor..end] --qos=1 --retain
      cursor = end
    firmware_info ::= ubjson.encode {
        "size": firmware_bin.size,
        "parts": parts,
    }
    client.publish "toit/firmware/$id" firmware_info --qos=1 --retain
  else:
    upload_supabase client "firmware/$id" firmware_bin
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

with_mqtt [block]:
  network := net.open
  transport := create_transport network
  client/mqtt.Client? := null
  try:
    client = mqtt.Client --transport=transport
    options := mqtt.SessionOptions --client_id=CLIENT_ID --clean_session
    client.start --options=options
    block.call client
  finally:
    if client: client.close
    network.close

/**
Gets current config for the specified $device.
Calls the $block with the current config, and gets a new config back.
Sends the new config to the device.
*/
update_postgrest_config device/DevicePostgrest [block]:
  // TODO(kasper): Share more of this code with the corresponding
  // code in the service.
  network := net.open
  client := create_client network
  headers := create_headers
  info := query client headers "devices" [
    "name=eq.$(device.name)",
  ]
  id := null
  old_config := {:}
  if info.size == 1 and info[0] is Map:
    id = info[0].get "id"
    old_config = info[0].get "config" or old_config

  new_config := block.call old_config client
  upsert := id ? "?id=eq.$id" : ""

  map := {
    "config": new_config
  }
  if id:
    map["id"] = id
    headers.add "Prefer" "resolution=merge-duplicates"

  payload := json.encode map
  response := client.post payload
      --host=SUPABASE_HOST
      --headers=headers
      --path="/rest/v1/devices$upsert"
  // 201 is changed one entry.
  if response.status_code != 201: throw "UGH ($response.status_code)"
  network.close

/**
Gets current config for the specified $device.
Calls the $block with the current config, and gets a new config back.
Sends the new config to the device.
*/
update_config device/DeviceMqtt [block]:
  with_mqtt: | client/mqtt.Client |
    locked := monitor.Latch
    config_channel := monitor.Channel 1
    revision_channel := monitor.Channel 1
    me := "cli-$(random 0x3fff_ffff)-$(Time.now.ns_part)"

    others := 0
    client.subscribe device.topic_lock:: | topic/string payload/ByteArray |
      writer := ubjson.decode payload
      if not writer:
        others = 0
        print "$(%08d Time.monotonic_us): Trying to acquire lock"
        client.publish device.topic_lock (ubjson.encode me)  --qos=1 --retain
      else if writer == me:
        if others == 0:
          print "$(%08d Time.monotonic_us): Acquired lock"
          locked.set me
        else:
          // Someone else locked this before us. Just wait.
          print "$(%08d Time.monotonic_us): Another writer acquired the lock"
      else:
        others++

    // We use the '--retain' flag when trying to acquire the lock.
    // If nobody ever took the lock, then we might need to wait for the
    // timeout here. Otherwise, the broker should send the current lock holder
    // immediately.
    exception := catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
      with_timeout --ms=5_000:
        locked.get
    if exception == DEADLINE_EXCEEDED_ERROR and others == 0:
      // We assume that nobody has taken the lock so far.
      print "$(%08d Time.monotonic_us): Trying to initialize writer lock"
      client.publish device.topic_lock (ubjson.encode me) --qos=1 --retain

      exception = catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=5_000:
          locked.get

    // We didn't get the lock.
    // TODO(florian): in theory we might just now get the lock. However, we
    // will not release it. This could lead to a bad state.
    if exception == DEADLINE_EXCEEDED_ERROR:
      print "$(%08d Time.monotonic_us): Timed out waiting for writer lock"
      return

    try:
      // We send config and revision changes with `--retain`.
      // As such we should get a packet as soon as we subscribe to the topics.

      client.subscribe device.topic_config:: | topic/string payload/ByteArray |
        if not config_channel.try_send (ubjson.decode payload):
          // TODO(kasper): Tell main task.
          throw "FATAL: Received too many configs"

      client.subscribe device.topic_revision:: | topic/string payload/ByteArray |
        if not revision_channel.try_send (ubjson.decode payload):
          // TODO(kasper): Tell main task.
          throw "FATAL: Received too many revision"

      config := null
      exception = catch
          --trace=(: it != DEADLINE_EXCEEDED_ERROR)
          --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=5_000:
          config = config_channel.receive
      if exception == DEADLINE_EXCEEDED_ERROR:
        print "$(%08d Time.monotonic_us): Trying to initialize config"
        client.publish device.topic_config (ubjson.encode {"revision": 0}) --qos=1 --retain
        client.publish device.topic_revision (ubjson.encode 0) --qos=1 --retain

        exception = catch --trace --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
          with_timeout --ms=5_000:
            config = config_channel.receive
        if exception == DEADLINE_EXCEEDED_ERROR:
          print "$(%08d Time.monotonic_us): Timed out waiting for config"
          return

      old_revision := revision_channel.receive
      if old_revision != config["revision"]:
        throw "FATAL: Revision mismatch"

      revision := old_revision + 1
      config["writer"] = me
      config["revision"] = revision
      config = block.call config client

      // TODO(kasper): Maybe validate the config?
      client.publish device.topic_config (ubjson.encode config) --qos=1 --retain
      if config_channel.receive["writer"] != me:
        throw "FATAL: Wrong writer in updated config"

      client.publish device.topic_revision (ubjson.encode revision) --qos=1 --retain
      if revision_channel.receive != revision:
        throw "FATAL: Wrong revision in updated config"

      print "Updated config to $config"

    finally:
      critical_do:
        print "$(%08d Time.monotonic_us): Releasing lock"
        client.publish device.topic_lock (ubjson.encode null) --retain

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

print_status device/DeviceMqtt:
  with_timeout --ms=5_000:
    with_mqtt: | client/mqtt.Client |
      status := monitor.Latch
      config := monitor.Latch
      client.subscribe device.topic_presence:: | topic/string payload/ByteArray |
        status.set payload.to_string
      client.subscribe device.topic_config:: | topic/string payload/ByteArray |
        config.set (ubjson.decode payload)
      print "Device: $device.name"
      print "  $status.get"
      print "  $config.get"

watch_presence:
  with_mqtt: | client/mqtt.Client |
    client.subscribe "toit/devices/presence/#":: | topic/string payload/ByteArray |
      device_name := (topic.split "/").last
      print "$(%08d Time.monotonic_us): $device_name: $payload.to_string"
    // Wait forever.
    (monitor.Latch).get
