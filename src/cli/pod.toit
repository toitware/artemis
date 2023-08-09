// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar show *
import bytes
import crypto.sha256
import encoding.json
import encoding.base64
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
  static NAME_NAME_ ::= "name"
  static CUSTOMIZED_ENVELOPE_NAME_ := "customized.env"
  static CHIP_NAME_ ::= "chip"

  static MAGIC_CONTENT_ ::= "frickin' sharks"

  envelope/ByteArray
  id/uuid.Uuid
  name/string
  chip/string

  envelope_path_/string? := null
  sdk_version_/string? := null
  device_config_/Map? := null
  tmp_dir_/string := ?

  constructor
      --.id
      --.name
      --.chip
      --tmp_directory/string
      --.envelope
      --envelope_path/string?=null:
    tmp_dir_ = tmp_directory

  constructor.from_specification
      --organization_id/uuid.Uuid
      --path/string
      --artemis/Artemis
      --ui/Ui:
    specification := parse_pod_specification_file path --ui=ui
    return Pod.from_specification
        --organization_id=organization_id
        --specification=specification
        --artemis=artemis

  constructor.from_specification
      --organization_id/uuid.Uuid
      --specification/PodSpecification
      --artemis/Artemis:
    envelope_path := generate_envelope_path_ --tmp_directory=artemis.tmp_directory
    artemis.customize_envelope
        --organization_id=organization_id
        --output_path=envelope_path
        --specification=specification
    envelope := file.read_content envelope_path
    id := random_uuid
    chip := specification.chip or "esp32"
    return Pod
        --id=id
        --name=specification.name
        --chip=chip
        --tmp_directory=artemis.tmp_directory
        --envelope=envelope
        --envelope_path=envelope_path

  constructor.from_manifest manifest/Map [--download] --tmp_directory/string:
    id = uuid.parse manifest[ID_NAME_]
    name = manifest[NAME_NAME_]
    chip = (manifest.get "chip") or "esp32"
    parts := manifest["parts"]
    byte_builder := bytes.Buffer
    writer := ArWriter byte_builder
    parts.do: | name/string part_id/string |
      writer.add name (download.call part_id)
    byte_builder.close
    envelope = byte_builder.buffer
    tmp_dir_ = tmp_directory

  static parse path/string --tmp_directory/string --ui/Ui -> Pod:
    read_file path --ui=ui: | reader/Reader |
      id/uuid.Uuid? := null
      name/string? := null
      chip/string? := null
      envelope/ByteArray? := null

      ar_reader := ArReader reader
      file := ar_reader.next
      if file.name != MAGIC_NAME_ or file.content != MAGIC_CONTENT_.to_byte_array:
        ui.abort "The file at '$path' is not a valid Artemis pod."

      while true:
        file = ar_reader.next
        if not file: break
        if file.name == ID_NAME_:
          if id:
            ui.abort "The file at '$path' is not a valid Artemis pod. It contains multiple IDs."
          id = uuid.Uuid file.content
        else if file.name == CHIP_NAME_:
          if chip:
            ui.abort "The file at '$path' is not a valid Artemis pod. It contains multiple chip entries."
          chip = file.content.to_string
        else if file.name == NAME_NAME_:
          if name:
            ui.abort "The file at '$path' is not a valid Artemis pod. It contains multiple names."
          name = file.content.to_string
        else if file.name == CUSTOMIZED_ENVELOPE_NAME_:
          if envelope:
            ui.abort "The file at '$path' is not a valid Artemis pod. It contains multiple envelopes."
          envelope = file.content

      if not id:       ui.abort "The file at '$path' is not a valid Artemis pod. It does not contain an ID."
      if not name:     ui.abort "The file at '$path' is not a valid Artemis pod. It does not contain a name."
      if not envelope: ui.abort "The file at '$path' is not a valid Artemis pod. It does not contain an envelope."

      if not chip: chip = "esp32"
      return Pod --id=id --chip=chip --name=name --envelope=envelope
          --tmp_directory=tmp_directory
    unreachable

  constructor.from_file path/string --organization_id/uuid.Uuid --artemis/Artemis --ui/Ui:
    if not file.is_file path:
      ui.abort "The file '$path' does not exist or is not a regular file."

    is_compiled_pod := false
    catch --unwind=(: it != "Invalid Ar File"):
      stream := file.Stream.for_read path
      try:
        ArReader stream
        is_compiled_pod = true
      finally:
        stream.close
    pod/Pod := ?
    if is_compiled_pod:
      return Pod.parse path --tmp_directory=artemis.tmp_directory --ui=ui
    else:
      return Pod.from_specification
          --organization_id=organization_id
          --path=path
          --artemis=artemis
          --ui=ui

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
      ar_writer.add NAME_NAME_ name.to_byte_array
      ar_writer.add CHIP_NAME_ chip.to_byte_array
      ar_writer.add CUSTOMIZED_ENVELOPE_NAME_ envelope

  /**
  Splits this pod into smaller parts.

  The given $block is called with a "manifest" (a $Map), and
    parts (as a $Map from name to $ByteArray).

  Together, these can be used to reconstruct the pod.
  */
  split [block] -> none:
    manifest := {:}
    manifest[ID_NAME_] = "$id"
    manifest[NAME_NAME_] = name
    manifest[CHIP_NAME_] = chip
    part_names := {:}
    parts := {:}
    reader := bytes.Reader envelope
    ar_reader := ArReader reader
    while file := ar_reader.next:
      // TODO(florian): if we wanted to have an easy way to find
      // snapshots, we should use the uuid of the snapshot (when it is one).
      hash := sha256.sha256 file.content
      part_name := base64.encode hash --url_mode
      part_names[file.name] = part_name
      parts[part_name] = file.content
    manifest["parts"] = part_names
    block.call manifest parts
