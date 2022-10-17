// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe
import host.file
import bytes
import crypto.sha256

import system.assets
import system.services
import system.api.firmware show FirmwareService

import encoding.json
import encoding.ubjson
import encoding.base64
import encoding.tison
import encoding.hex

import ..broker show decode_broker
import ..service show run_artemis
import ..status show report_status_setup

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
      --encoding=parsed["firmware"]
      --bits=bits

run_host --identity/Map --encoding/string --bits/ByteArray? -> none:
  service := FirmwareServiceDefinition bits
  service.install

  identity["artemis.broker"] = tison.encode identity["artemis.broker"]
  identity["broker"] = tison.encode identity["broker"]

  device := report_status_setup identity identity["artemis.device"]
  broker := decode_broker "broker" identity
  run_artemis device broker --firmware=encoding

// --------------------------------------------------------------------------

class FirmwareServiceDefinition extends services.ServiceDefinition:
  content_/ByteArray?

  constructor .content_:
    super "system/firmware/artemis" --major=0 --minor=1
    provides FirmwareService.UUID FirmwareService.MAJOR FirmwareService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == FirmwareService.IS_VALIDATION_PENDING_INDEX:
      return is_validation_pending
    if index == FirmwareService.IS_ROLLBACK_POSSIBLE_INDEX:
      return is_rollback_possible
    if index == FirmwareService.VALIDATE_INDEX:
      return validate
    if index == FirmwareService.UPGRADE_INDEX:
      return upgrade
    if index == FirmwareService.ROLLBACK_INDEX:
      return rollback
    if index == FirmwareService.CONFIG_UBJSON_INDEX:
      return config_ubjson
    if index == FirmwareService.CONFIG_ENTRY_INDEX:
      return config_entry arguments
    if index == FirmwareService.CONTENT_INDEX:
      return content
    if index == FirmwareService.FIRMWARE_WRITER_OPEN_INDEX:
      return firmware_writer_open client arguments[0] arguments[1]
    if index == FirmwareService.FIRMWARE_WRITER_WRITE_INDEX:
      writer ::= (resource client arguments[0]) as FirmwareWriter
      return firmware_writer_write writer arguments[1]
    if index == FirmwareService.FIRMWARE_WRITER_PAD_INDEX:
      writer ::= (resource client arguments[0]) as FirmwareWriter
      return firmware_writer_pad writer arguments[1] arguments[2]
    if index == FirmwareService.FIRMWARE_WRITER_COMMIT_INDEX:
      writer ::= (resource client arguments[0]) as FirmwareWriter
      return firmware_writer_commit writer arguments[1]
    unreachable

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

  firmware_writer_open from/int to/int -> int:
    unreachable  // TODO(kasper): Nasty.

  firmware_writer_open client/int from/int to/int -> services.ServiceResource:
    return FirmwareWriter this client from to

  firmware_writer_write writer/FirmwareWriter bytes/ByteArray -> none:
    writer.write bytes

  firmware_writer_pad writer/FirmwareWriter size/int value/int -> none:
    writer.pad size value

  firmware_writer_commit writer/FirmwareWriter checksum/ByteArray? -> none:
    writer.commit checksum

class FirmwareWriter extends services.ServiceResource:
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
