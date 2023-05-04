// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar show *
import encoding.json
import host.file
import writer show Writer
import reader show Reader
import uuid

import .artemis
import .cache
import .pod_specification
import .sdk
import .ui
import .utils

/**
An Artemis pod contains all the information to run containers on a device.

It contains the customized firmware envelope.
*/
class Pod:
  // Ar files can only have 15 chars for the name.
  static MAGIC_NAME_ ::= "artemis-pod"
  static ID_NAME_ ::= "id"
  static CUSTOMIZED_ENVELOPE_NAME_ := "customized.env"

  static MAGIC_CONTENT_ ::= "frickin' sharks"

  envelope/ByteArray
  id/uuid.Uuid

  envelope_path_/string? := null
  sdk_version_/string? := null
  device_config_/Map? := null
  tmp_dir_/string := ?

  constructor --.id --tmp_directory/string --.envelope --envelope_path/string?=null:
    tmp_dir_ = tmp_directory

  constructor.from_specification --path/string --artemis/Artemis --ui/Ui:
    specification := parse_pod_specification_file path --ui=ui
    return Pod.from_specification --specification=specification --artemis=artemis

  constructor.from_specification --specification/PodSpecification --artemis/Artemis:
    envelope_path := generate_envelope_path_ --tmp_directory=artemis.tmp_directory
    artemis.customize_envelope
        --output_path=envelope_path
        --specification=specification
    envelope := file.read_content envelope_path
    id := random_uuid
    return Pod
        --id=id
        --tmp_directory=artemis.tmp_directory
        --envelope=envelope
        --envelope_path=envelope_path

  static parse path/string --tmp_directory/string --ui/Ui -> Pod:
    read_file path --ui=ui: | reader/Reader |
      ar_reader := ArReader reader
      file := ar_reader.next
      if file.name != MAGIC_NAME_ or file.content != MAGIC_CONTENT_.to_byte_array:
        ui.abort "The file at '$path' is not a valid Artemis pod."
      file = ar_reader.next
      if file.name != ID_NAME_:
        ui.abort "The file at '$path' is not a valid Artemis pod."
      id := uuid.Uuid file.content
      if file.name != CUSTOMIZED_ENVELOPE_NAME_:
        ui.abort "The file at '$path' is not a valid Artemis pod."
      envelope := file.content
      return Pod --id=id --tmp_directory=tmp_directory --envelope=envelope
    unreachable

  static envelope_count_/int := 0
  static generate_envelope_path_ --tmp_directory/string -> string:
    return "$tmp_directory/pod-$(envelope_count_++).envelope"

  sdk_version -> string:
    cached := sdk_version_
    if cached: return cached
    cached = Sdk.get_sdk_version_from --envelope=envelope
    sdk_version_ = cached
    return cached

  envelope_path -> string:
    cached := envelope_path_
    if cached: return cached
    cached = generate_envelope_path_ --tmp_directory=tmp_dir_
    write_blob_to_file cached envelope
    envelope_path_ = cached
    return cached

  device_config --sdk/Sdk -> Map:
    cached := device_config_
    if cached: return cached
    with_tmp_directory: | tmp_dir/string |
      assets_path := "$tmp_dir/assets"
      sdk.firmware_extract_container
          --name="artemis"  // TODO(florian): use constants for hard-coded names.
          --assets
          --envelope_path=envelope_path
          --output_path=assets_path
      config_asset := sdk.assets_extract
          --name="device-config"
          --format="ubjson"
          --assets_path=assets_path
      cached = json.decode config_asset
    device_config_ = cached
    return cached

  write path/string --ui/Ui:
    write_file path --ui=ui: | writer/Writer |
      ar_writer := ArWriter writer
      ar_writer.add MAGIC_NAME_ MAGIC_CONTENT_
      ar_writer.add ID_NAME_ id.to_byte_array
      ar_writer.add CUSTOMIZED_ENVELOPE_NAME_ envelope
