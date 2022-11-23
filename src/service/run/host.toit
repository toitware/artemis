// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe
import host.file
import bytes
import crypto.sha256

import system.assets
import system.services

import system.base.firmware show FirmwareWriter FirmwareServiceDefinitionBase

import encoding.json
import encoding.ubjson
import encoding.base64
import encoding.tison
import encoding.hex

import ..broker show decode_broker_config
import ..service show run_artemis
import ..check_in show check_in_setup
import ..device

main arguments:
  root_cmd := cli.Command "root"
      --options=[
        cli.OptionString "firmware"
            --required,
        cli.OptionString "identity"
            --type="file"
            --required,
        cli.OptionString "old"
            --type="file",
      ]
      --run=:: run it
  root_cmd.run arguments

run parsed/cli.Parsed -> none:
  bits := null
  if parsed["old"]: bits = file.read_content parsed["old"]

  identity_raw := file.read_content parsed["identity"]
  identity := ubjson.decode (base64.decode identity_raw)
  run_host
      --identity=identity
      --encoded=parsed["firmware"]
      --bits=bits

run_host --identity/Map --encoded/string --bits/ByteArray? -> none:
  service := FirmwareServiceDefinition bits
  service.install

  identity["artemis.broker"] = tison.encode identity["artemis.broker"]
  identity["broker"] = tison.encode identity["broker"]

  check_in_setup identity identity["artemis.device"]
  device := Device --id=identity["device_id"] --firmware=encoded
  broker_config := decode_broker_config "broker" identity
  run_artemis device broker_config

// --------------------------------------------------------------------------

class FirmwareServiceDefinition extends FirmwareServiceDefinitionBase:
  content_/ByteArray?

  constructor .content_:
    super "system/firmware/artemis" --major=0 --minor=1

  is_validation_pending -> bool:
    return false

  is_rollback_possible -> bool:
    return false

  validate -> bool:
    throw "UNIMPLEMENTED"

  rollback -> none:
    throw "UNIMPLEMENTED"

  upgrade -> none:
    // TODO(kasper): Ignored for now.

  config_ubjson -> ByteArray:
    return ByteArray 0

  config_entry key/string -> any:
    return null

  content:
    // TODO(kasper): Avoid this copy. We need it right now
    // because otherwise we run into trouble because we
    // seem to receive a 'proxy', not a proper external
    // byte array on the other side.
    return content_.copy

  firmware_writer_open client/int from/int to/int -> FirmwareWriter:
    return FirmwareWriter_ this client from to

class FirmwareWriter_ extends services.ServiceResource implements FirmwareWriter:
  static image/ByteArray := #[]
  view_/ByteArray? := null
  cursor_/int := 0

  constructor service/FirmwareServiceDefinition client/int from/int to/int:
    if to > image.size: image = image + (ByteArray to - image.size: random 0x100)
    view_ = image[from..to]
    super service client

  write bytes/ByteArray from=0 to=bytes.size -> none:
    view_.replace cursor_ bytes[from..to]
    cursor_ += to - from

  pad size/int value/int -> none:
    to := cursor_ + size
    view_.fill --from=cursor_ --to=to value
    cursor_ = to

  flush -> int:
    // Everything is already flushed.
    return 0

  commit checksum/ByteArray? -> none:
    print "Got a grand total of $image.size bytes"
    sha := sha256.Sha256
    sha.add image[..image.size - 32]
    print "Computed checksum = $(hex.encode sha.get)"
    print "Provided checksum = $(hex.encode image[image.size - 32..])"
    view_ = null

  on_closed -> none:
    if not view_: return
    view_ = null
