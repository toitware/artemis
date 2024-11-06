// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import cli show Cli FileStore
import crypto.sha256
import encoding.base64
import encoding.ubjson
import host.file
import host.os
import io
import snapshot show cache-snapshot
import uuid show Uuid
import fs
import semver

import .sdk
import .cache show cache-key-url-artifact CACHE-ARTIFACT-KIND-ENVELOPE CACHE-ARTIFACT-KIND-PARTITION-TABLE
import .cache as cli
import .device
import .pod
import .pod-specification
import .utils
import ..shared.utils.patch


/**
A firmware for a specific device.

Contains the generic $content which is shared among devices that use the same firmware version.
In addition, it contains the $device-specific-data which is unique to the device.
*/
class Firmware:
  /**
  The generic firmware.
  The generic firmware can be shared among different devices.
  The content always contains a description, identifying the firmware, but does not
    always contain the actual bytes.
  */
  content/FirmwareContent
  /**
  An encoded description of this firmware.
  Contains the $device-specific-data, and a checksum of the $content.
  */
  encoded/string
  /**
  The device-specific data.

  This data contains information such as the device ID, the organization ID,
    the hardware ID and the wifi configuration. It also contains the "parts"
    field which describes the individual parts of the firmware, and the sdk
    version that was used to create the firmware.
  */
  device-specific-data/ByteArray
  /** A decoded version of the $device-specific-data. */
  device-specific-data_/Map

  constructor .content .device-specific-data:
    map := {
      "device-specific": device-specific-data,
      "checksum": content.checksum }
    encoded = base64.encode (ubjson.encode map)
    device-specific-data_ = ubjson.decode device-specific-data
    if not device-specific-data_.contains "artemis.device":
      throw "Invalid device-specific data: Missing artemis.device"
    if not device-specific-data_.contains "parts":
      throw "Invalid device-specific data: Missing parts"
    if not device-specific-data_.contains "sdk-version":
      throw "Invalid device-specific data: Missing sdk-version"
    assert: device-specific-data_["parts"] == content.encoded-parts

  constructor.encoded .encoded:
    map := ubjson.decode (base64.decode encoded)
    device-specific-data = map["device-specific"]
    device-specific-data_ = ubjson.decode device-specific-data
    content = FirmwareContent.encoded device-specific-data_["parts"] --checksum=map["checksum"]

  /**
  Embeds device-specific information in $device into a firmware given by
    its pod.

  If the $unconfigured-content isn't given, it is extracted from the pod.
  If it is given, then the pod is only used for its ID.

  Computes the "parts" which describes the individual parts of the
    firmware. Most parts consist of a range, and the binary hash of its content.
    Some parts, like the one containing the device-specific information only
    contains its range. The parts description is then encoded with ubjson and
    also stored in the device-specific information part (under the name "parts").

  Since adding the encoded parts to the device-specific information part
    may change the size of the part (and thus the ranges of the other parts),
    the process is repeated until the encoded parts do not change anymore.
  */
  constructor --device/Device --pod/Pod --cli/Cli --unconfigured-content/FirmwareContent?=null:
    sdk-version := Sdk.get-sdk-version-from --envelope-path=pod.envelope-path
    unconfigured := unconfigured-content or
        FirmwareContent.from-envelope pod.envelope-path --cli=cli
    encoded-parts := unconfigured.encoded-parts
    device-map := {
      "device_id":       "$device.id",
      "organization_id": "$device.organization-id",
      "hardware_id":     "$device.hardware-id",
    }
    while true:
      device-specific := ubjson.encode {
        "artemis.device" : device-map,
        "parts"          : encoded-parts,
        // TODO(florian): these don't feel like they are device-specific properties.
        "sdk-version"    : sdk-version,
        "pod-id"         : pod.id.to-byte-array,
      }

      configured := FirmwareContent.from-envelope pod.envelope-path
          --device-specific=device-specific
          --cli=cli
      if configured.encoded-parts == encoded-parts:
        return Firmware configured device-specific
      encoded-parts = configured.encoded-parts

  device-specific key/string -> any:
    return device-specific-data_.get key

  device -> Device:
    device-map := device-specific "artemis.device"
    return Device
        --id=Uuid.parse device-map["device_id"]
        --organization-id=Uuid.parse device-map["organization_id"]
        --hardware-id=Uuid.parse device-map["hardware_id"]

  /** The sdk version that was used for this firmware. */
  sdk-version -> string:
    return device-specific "sdk-version"

  pod-id -> Uuid:
    // TODO(kasper): Device configurations prior to Artemis v0.6
    // do not (generally) contain pod ids. To ease migration, we
    // let them have a nil id to indicate that we don't know which
    // pod they are running. It feels safe to remove this workaround
    // in a couple of weeks (early June, 2023).
    device-pod-id := device-specific "pod-id"
    if not device-pod-id: return Uuid.NIL
    return Uuid device-pod-id

class FirmwareContent:
  bits/ByteArray?
  parts/List
  checksum/ByteArray
  encoded-parts/ByteArray

  constructor --.bits --.parts --.checksum:
    encoded-parts = ubjson.encode (parts.map: it.encode)

  constructor.encoded .encoded-parts --.checksum:
    bits = null
    list := ubjson.decode encoded-parts
    parts = list.map: FirmwarePart.encoded it

  constructor.from-envelope envelope-path/string --device-specific/ByteArray?=null --cli/Cli:
    sdk-version := Sdk.get-sdk-version-from --envelope-path=envelope-path
    sdk := get-sdk sdk-version --cli=cli
    firmware-description/Map := {:}
    if device-specific:
      with-tmp-directory: | tmp-dir/string |
        device-specific-path := tmp-dir + "/device_specific"
        write-blob-to-file device-specific-path device-specific
        firmware-description = sdk.firmware-extract
            --envelope-path=envelope-path
            --device-specific-path=device-specific-path
    else:
      firmware-description = sdk.firmware-extract --envelope-path=envelope-path

    bits := firmware-description["binary"]
    checksum/ByteArray? := null

    parts := []
    firmware-description["parts"].do: | entry/Map |
      from := entry["from"]
      to := entry["to"]
      part-bits := bits[from..to]
      type := entry["type"]

      if type == "config":
        parts.add (FirmwarePartConfig --from=from --to=to)
      else if type == "checksum":
        checksum = part-bits
      else:
        parts.add (FirmwarePartPatch --from=from --to=to --bits=part-bits)

    return FirmwareContent --bits=bits --parts=parts --checksum=checksum

  patches from/FirmwareContent? -> List:
    result := []
    parts.size.repeat: | index/int |
      part := parts[index]
      if part is FirmwarePartConfig: continue.repeat
      // TODO(kasper): This should not just be based on index.
      old/FirmwarePartPatch? := null
      if from and index < from.parts.size: old = from.parts[index]
      if old and old.hash == part.hash:
        continue.repeat
      else if old:
        result.add (FirmwarePatch --bits=part.bits --from=old.hash --to=part.hash)
      else:
        result.add (FirmwarePatch --bits=part.bits --to=part.hash)
    return result

  trivial-patches -> List:
    result := []
    parts.do: | part/FirmwarePart |
      if part is FirmwarePartConfig: continue.do
      patch-part := part as FirmwarePartPatch
      result.add (FirmwarePatch --bits=patch-part.bits --to=patch-part.hash)
    return result

class PatchWriter implements PatchObserver:
  buffer/io.Buffer ::= io.Buffer
  size/int? := null
  on-write data from/int=0 to/int=data.size:
    buffer.write data[from..to]
  on-size size/int -> none:
    this.size = size
  on-new-checksum checksum/ByteArray -> none:
    // Do nothing.
  on-checkpoint patch-position/int -> none:
    // Do nothing.

class FirmwarePatch:
  bits_/ByteArray
  from_/ByteArray?
  to_/ByteArray

  constructor --bits/ByteArray --to/ByteArray --from/ByteArray?=null:
    bits_ = bits
    to_ = to
    from_ = from

abstract class FirmwarePart:
  from/int
  to/int
  constructor .from .to:

  constructor.encoded map/Map:
    type := map.get "type"
    if type == "config": return FirmwarePartConfig.encoded map
    else: return FirmwarePartPatch.encoded map

  abstract encode -> Map

class FirmwarePartPatch extends FirmwarePart:
  bits/ByteArray? := null
  hash/ByteArray

  constructor --from/int --to/int --.bits/ByteArray:
    sha := sha256.Sha256
    sha.add bits
    hash = sha.get
    super from to

  constructor --from/int --to/int --.hash:
    super from to

  constructor.encoded map/Map:
    return FirmwarePartPatch --from=map["from"] --to=map["to"] --hash=map["hash"]

  encode -> Map:
    return { "from": from, "to": to, "hash": hash }

class FirmwarePartConfig extends FirmwarePart:
  constructor --from/int --to/int:
    super from to

  constructor.encoded map/Map:
    return FirmwarePartConfig --from=map["from"] --to=map["to"]

  encode -> Map:
    return { "from": from, "to": to, "type": "config" }

/**
Stores the snapshots inside the envelope in the user's snapshot directory.
*/
cache-snapshots --envelope-path/string --output-directory/string?=null --cli/Cli:
  sdk-version := Sdk.get-sdk-version-from --envelope-path=envelope-path
  sdk := get-sdk sdk-version --cli=cli
  containers := sdk.firmware-list-containers --envelope-path=envelope-path
  with-tmp-directory: | tmp-dir/string |
    containers.do: | name/string description/Map |
      if description["kind"] == "snapshot":
        id := description["id"]
        tmp-snapshot-path := "$tmp-dir/$(id).snapshot"
        sdk.firmware-extract-container
            --envelope-path=envelope-path
            --name=name
            --output-path=tmp-snapshot-path
        snapshot-content := file.read-content tmp-snapshot-path
        cache-snapshot snapshot-content --output-directory=output-directory

// A forwarding function to work around the shadowing in 'get_envelope'.
cache-snapshots_ --envelope-path/string --cli/Cli:
  cache-snapshots --envelope-path=envelope-path --cli=cli

is-valid-release-artifact-name_ name/string -> bool:
  name.do: | c/int |
    if not is-alnum_ c and c != '-' and c != '_': return false
  return true

/**
Builds the URL for the firmware envelope for the given $sdk-version and $envelope.

If no envelope is given, builds a URL for the envelopes from Toit's
  Github repository.
*/
build-envelope-url --sdk-version/string? --envelope/string -> string:
  if is-valid-release-artifact-name_ envelope:
    if not sdk-version:
      throw "No sdk_version given"
    if (semver.compare sdk-version "2.0.0-alpha.97") < 0:
      // Backwards compatibility for old SDKs.
      return "https://github.com/toitlang/toit/releases/download/$sdk-version/firmware-$(envelope).gz"
    return "https://github.com/toitlang/envelopes/releases/download/$sdk-version/firmware-$(envelope).envelope.gz"

  if sdk-version:
    envelope = envelope.replace --all "\$(sdk-version)" sdk-version

  URL-PREFIXES ::= ["http://", "https://", "file://"]
  URL-PREFIXES.do: if envelope.starts-with it: return envelope
  return "file://$envelope"

build-partition-table-url --sdk-version/string? --partition-table/string -> string:
  if is-valid-release-artifact-name_ partition-table:
    if not sdk-version:
      throw "No sdk_version given"
    if (semver.compare sdk-version "2.0.0-alpha.163") < 0:
      throw "Partition tables are not supported for SDK versions older than 2.0.0-alpha.163"
    return "https://github.com/toitlang/envelopes/releases/download/$sdk-version/partition-table-$(partition-table).csv"

  if sdk-version:
    partition-table = partition-table.replace --all "\$(sdk-version)" sdk-version

  URL-PREFIXES ::= ["http://", "https://", "file://"]
  URL-PREFIXES.do: if partition-table.starts-with it: return partition-table
  return "file://$partition-table"

get-artifact_ -> string
    kind/string
    --url/string
    --specification/PodSpecification
    --cli/Cli
    [--after-download]:
  sdk-version := specification.sdk-version

  FILE-URL-PREFIX ::= "file://"
  if url.starts-with FILE-URL-PREFIX:
    path := url.trim --left FILE-URL-PREFIX
    if fs.is-relative path:
      return "$specification.relative-to/$path"
    return path

  HTTP-URL-PREFIX ::= "http://"
  HTTPS-URL-PREFIX ::= "https://"
  if not url.starts-with HTTP-URL-PREFIX and not url.starts-with HTTPS-URL-PREFIX:
    throw "Invalid $kind URL: $url"

  cache-key := cache-key-url-artifact --url=url --kind=kind
  return cli.cache.get-file-path cache-key: | store/FileStore |
    store.with-tmp-directory: | tmp-dir |
      out-path := "$tmp-dir/artifact"
      artifact-path := out-path
      is-gz-file := url.ends-with ".gz"
      if is-gz-file: out-path += ".gz"
      download-url url --out-path=out-path --cli=cli
      if is-gz-file:
        gunzip out-path
      after-download.call artifact-path
      store.move artifact-path

reported-local-envelope-use_/bool := false
/**
Returns a path to the firmware envelope for the given $specification.

If $cache-snapshots is true, then copies the contained snapshots
  into the cache.
*/
// TODO(florian): we probably want to create a class for the firmware
// envelope.
get-envelope -> string
    --specification/PodSpecification
    --cache-snapshots/bool=true
    --cli/Cli:
  if is-dev-setup:
    envelope := specification.envelope
    local-sdk := os.env.get "DEV_TOIT_REPO_PATH"
    if local-sdk:
      envelope-path := "$local-sdk/build/$envelope/firmware.envelope"
      if not reported-local-envelope-use_:
        print-on-stderr_ "Using envelope from local SDK: '$envelope-path'"
        reported-local-envelope-use_ = true
      return envelope-path

  sdk-version := specification.sdk-version
  envelope := specification.envelope

  url := build-envelope-url --sdk-version=sdk-version --envelope=envelope

  return get-artifact_ CACHE-ARTIFACT-KIND-ENVELOPE
      --url=url
      --specification=specification
      --cli=cli
      --after-download=: | envelope-path |
          if cache-snapshots:
            cache-snapshots_ --envelope-path=envelope-path --cli=cli

get-partition-table -> ByteArray
    --specification/PodSpecification
    --cli/Cli:
  partition-table-entry := specification.partition-table
  url := build-partition-table-url
      --sdk-version=specification.sdk-version
      --partition-table=partition-table-entry

  path := get-artifact_ CACHE-ARTIFACT-KIND-PARTITION-TABLE
      --url=url
      --specification=specification
      --cli=cli
      --after-download=: null  // Do nothing.

  return file.read-content path
