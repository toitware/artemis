// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar show *
import crypto.sha256
import encoding.json
import encoding.base64
import encoding.ubjson
import host.file
import io
import uuid

import .artemis
import .broker
import .cache
import .device
import .firmware show Firmware
import .pod-specification
import .sdk
import .server-config
import .ui
import .utils

/**
An Artemis pod contains all the information to run containers on a device.

It contains the customized firmware envelope.
*/
class Pod:
  // Ar files can only have 15 chars for the name.
  static MAGIC-NAME_ ::= "artemis-pod"
  static ID-NAME_ ::= "id"
  static NAME-NAME_ ::= "name"
  static CUSTOMIZED-ENVELOPE-NAME_ := "customized.env"

  static MAGIC-CONTENT_ ::= "frickin' sharks"

  envelope/ByteArray
  id/uuid.Uuid
  name/string

  envelope-path_/string? := null
  sdk-version_/string? := null
  device-config_/Map? := null
  tmp-dir_/string := ?

  constructor
      --.id
      --.name
      --tmp-directory/string
      --.envelope
      --envelope-path/string?=null:
    tmp-dir_ = tmp-directory

  constructor.from-specification
      --organization-id/uuid.Uuid
      --path/string
      --artemis/Artemis
      --broker/Broker
      --ui/Ui:
    specification := parse-pod-specification-file path --ui=ui
    return Pod.from-specification
        --organization-id=organization-id
        --specification=specification
        --artemis=artemis
        --broker=broker

  constructor.from-specification
      --organization-id/uuid.Uuid
      --specification/PodSpecification
      --broker/Broker
      --artemis/Artemis:
    envelope-path := generate-envelope-path_ --tmp-directory=artemis.tmp-directory
    broker.customize-envelope
        --organization-id=organization-id
        --output-path=envelope-path
        --artemis=artemis
        --specification=specification
    envelope := file.read-content envelope-path
    id := random-uuid
    return Pod
        --id=id
        --name=specification.name
        --tmp-directory=artemis.tmp-directory
        --envelope=envelope
        --envelope-path=envelope-path

  constructor.from-manifest manifest/Map [--download] --tmp-directory/string:
    id = uuid.parse manifest[ID-NAME_]
    name = manifest[NAME-NAME_]
    parts := manifest["parts"]
    byte-builder := io.Buffer
    writer := ArWriter byte-builder
    parts.do: | name/string part-id/string |
      writer.add name (download.call part-id)
    byte-builder.close
    envelope = byte-builder.bytes
    tmp-dir_ = tmp-directory

  static parse path/string --tmp-directory/string --ui/Ui -> Pod:
    read-file path --ui=ui: | reader/io.Reader |
      id/uuid.Uuid? := null
      name/string? := null
      envelope/ByteArray? := null

      ar-reader := ArReader reader
      file := ar-reader.next
      if file.name != MAGIC-NAME_ or file.content != MAGIC-CONTENT_.to-byte-array:
        ui.abort "The file at '$path' is not a valid Artemis pod."

      while true:
        file = ar-reader.next
        if not file: break
        if file.name == ID-NAME_:
          if id:
            ui.abort "The file at '$path' is not a valid Artemis pod. It contains multiple IDs."
          id = uuid.Uuid file.content
        else if file.name == NAME-NAME_:
          if name:
            ui.abort "The file at '$path' is not a valid Artemis pod. It contains multiple names."
          name = file.content.to-string
        else if file.name == CUSTOMIZED-ENVELOPE-NAME_:
          if envelope:
            ui.abort "The file at '$path' is not a valid Artemis pod. It contains multiple envelopes."
          envelope = file.content

      if not id:       ui.abort "The file at '$path' is not a valid Artemis pod. It does not contain an ID."
      if not name:     ui.abort "The file at '$path' is not a valid Artemis pod. It does not contain a name."
      if not envelope: ui.abort "The file at '$path' is not a valid Artemis pod. It does not contain an envelope."

      return Pod --id=id --name=name --envelope=envelope --tmp-directory=tmp-directory
    unreachable

  constructor.from-file
      path/string
      --organization-id/uuid.Uuid
      --artemis/Artemis
      --broker/Broker
      --ui/Ui:
    if not file.is-file path:
      ui.abort "The file '$path' does not exist or is not a regular file."

    is-compiled-pod := false
    catch --unwind=(: it != "Invalid Ar File"):
      stream := file.Stream.for-read path
      try:
        ArReader stream
        is-compiled-pod = true
      finally:
        stream.close
    pod/Pod := ?
    if is-compiled-pod:
      return Pod.parse path --tmp-directory=artemis.tmp-directory --ui=ui
    else:
      return Pod.from-specification
          --organization-id=organization-id
          --path=path
          --artemis=artemis
          --broker=broker
          --ui=ui

  static envelope-count_/int := 0
  static generate-envelope-path_ --tmp-directory/string -> string:
    return "$tmp-directory/pod-$(envelope-count_++).envelope"

  sdk-version -> string:
    cached := sdk-version_
    if cached: return cached
    cached = Sdk.get-sdk-version-from --envelope=envelope
    sdk-version_ = cached
    return cached

  envelope-path -> string:
    cached := envelope-path_
    if cached: return cached
    cached = generate-envelope-path_ --tmp-directory=tmp-dir_
    write-blob-to-file cached envelope
    envelope-path_ = cached
    return cached

  device-config --sdk/Sdk -> Map:
    cached := device-config_
    if cached: return cached
    with-tmp-directory: | tmp-dir/string |
      assets-path := "$tmp-dir/assets"
      sdk.firmware-extract-container
          --name="artemis"  // TODO(florian): use constants for hard-coded names.
          --assets
          --envelope-path=envelope-path
          --output-path=assets-path
      config-asset := sdk.assets-extract
          --name="device-config"
          --format="ubjson"
          --assets-path=assets-path
      cached = json.decode config-asset
    device-config_ = cached
    return cached

  write path/string --ui/Ui:
    write-file path --ui=ui: | writer/io.Writer |
      ar-writer := ArWriter writer
      ar-writer.add MAGIC-NAME_ MAGIC-CONTENT_
      ar-writer.add ID-NAME_ id.to-byte-array
      ar-writer.add NAME-NAME_ name.to-byte-array
      ar-writer.add CUSTOMIZED-ENVELOPE-NAME_ envelope

  /**
  Splits this pod into smaller parts.

  The given $block is called with a "manifest" (a $Map), and
    parts (as a $Map from name to $ByteArray).

  Together, these can be used to reconstruct the pod.
  */
  split [block] -> none:
    manifest := {:}
    manifest[ID-NAME_] = "$id"
    manifest[NAME-NAME_] = name
    part-names := {:}
    parts := {:}
    reader := io.Reader envelope
    ar-reader := ArReader reader
    while file := ar-reader.next:
      // TODO(florian): if we wanted to have an easy way to find
      // snapshots, we should use the uuid of the snapshot (when it is one).
      hash := sha256.sha256 file.content
      part-name := base64.encode hash --url-mode
      part-names[file.name] = part-name
      parts[part-name] = file.content
    manifest["parts"] = part-names
    block.call manifest parts

  /**
  Computes the device-specific data of the given envelope.

  Combines this pod and identity ($identity-path) into a single firmware image
    and computes the configuration which depends on the checksums of the
    individual parts.

  In this context the configuration consists of the checksums of the individual
    parts of the firmware image, combined with the configuration that was
    stored in the envelope.
  */
  compute-device-specific-data -> ByteArray
      --identity-path/string
      --cache/Cache
      --ui/Ui:
    // Use the SDK from the pod.
    sdk := get-sdk sdk-version --cache=cache

    // Extract the device ID from the identity file.
    // TODO(florian): abstract the identity management.
    identity-raw := file.read-content identity-path

    identity := ubjson.decode (base64.decode identity-raw)

    // Since we already have the identity content, check that the artemis server
    // is the same.
    // This is primarily a sanity check, and we might remove the broker from the
    // identity file in the future. Since users are not supposed to be able to
    // change the Artemis server, there wouldn't be much left of the check.
    // TODO(florian): remove this check?
    with-tmp-directory: | tmp/string |
      artemis-assets-path := "$tmp/artemis.assets"
      sdk.run-firmware-tool [
        "-e", envelope-path,
        "container", "extract",
        "-o", artemis-assets-path,
        "--part", "assets",
        "artemis"
      ]

      if not is-same-broker "broker" identity tmp artemis-assets-path sdk:
        ui.warning "The identity file and the Artemis assets in the envelope don't use the same broker"
      if not is-same-broker "artemis.broker" identity tmp artemis-assets-path sdk:
        ui.warning "The identity file and the Artemis assets in the envelope don't use the same Artemis server"

    device-map := identity["artemis.device"]
    device := Device
        --hardware-id=uuid.parse device-map["hardware_id"]
        --id=uuid.parse device-map["device_id"]
        --organization-id=uuid.parse device-map["organization_id"]

    // We don't really need the full firmware and just the device-specific data,
    // but by cooking the firmware we get the checksums correct.
    firmware := Firmware --pod=this --device=device --cache=cache

    return firmware.device-specific-data


  static is-same-broker broker/string identity/Map tmp/string assets-path/string sdk/Sdk -> bool:
    broker-path := "$tmp/broker.json"
    sdk.run-assets-tool [
      "-e", assets-path,
      "get", "--format=tison",
      "-o", broker-path,
      "broker"
    ]
    // TODO(kasper): This is pretty crappy.
    x := ((json.stringify identity["broker"]) + "\n").to-byte-array
    y := (file.read-content broker-path)
    return x == y
