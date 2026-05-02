// Copyright (C) 2026 Toit contributors.

import cli show Cli FileStore
import crypto.sha256
import encoding.base64
import host.file
import io
import uuid show Uuid

import .brokers.broker show BrokerCli
import .cache
import .firmware show FirmwareContents FirmwarePatch PatchWriter
import .pod show Pod
import .utils.patch-build show build-diff-patch build-trivial-patch
import ..shared.server-config
import ..shared.utils.patch show Patcher

/**
Uploads firmware patches (trivial and diff) to a broker's firmware
  storage on behalf of pod uploads and device roll-outs.

The uploader is bound to a specific (broker, organization) pair. Patch
  IDs are derived from the from/to firmware checksums; uploads are
  cached locally so repeated runs are cheap.
*/
class FirmwarePatchUploader:
  broker-connection_/BrokerCli
  server-config_/ServerConfig
  organization-id_/Uuid
  cli_/Cli

  constructor
      --broker-connection/BrokerCli
      --server-config/ServerConfig
      --organization-id/Uuid
      --cli/Cli:
    broker-connection_ = broker-connection
    server-config_ = server-config
    organization-id_ = organization-id
    cli_ = cli

  /**
  Uploads the trivial patches contained in $pod's firmware envelope.
  */
  upload-trivial-patches --pod/Pod -> none:
    firmware-contents := FirmwareContents.from-envelope pod.envelope-path --cli=cli_
    upload-trivial-patches --firmware-contents=firmware-contents

  /**
  Uploads the trivial patches contained in $firmware-contents.
  */
  upload-trivial-patches --firmware-contents/FirmwareContents -> none:
    firmware-contents.trivial-patches.do: diff-and-upload it

  /**
  Returns the trivial patches in $firmware-contents keyed by patch id.
  */
  static extract-trivial-patches firmware-contents/FirmwareContents -> Map:
    result := {:}
    firmware-contents.trivial-patches.do: | patch/FirmwarePatch |
      result[(id --to=patch.to_)] = patch
    return result

  /**
  Computes patches for the given $patch and uploads them to the broker.

  Always uploads the trivial patch (unless cached). If $patch carries
    a "from" hash, additionally attempts to compute and upload a diff
    patch from the previous trivial patch.
  */
  diff-and-upload patch/FirmwarePatch -> none:
    // Unless it is already cached, always create/upload the trivial one.
    trivial-id := id --to=patch.to_
    cache-key := cache-key-patch
        --broker-config=server-config_
        --organization-id=organization-id_
        --patch-id=trivial-id
    cli_.cache.get cache-key: | store/FileStore |
      trivial := build-trivial-patch patch.bits_
      broker-connection_.upload-firmware trivial
          --organization-id=organization-id_
          --firmware-id=trivial-id
      store.save-via-writer: | writer/io.Writer |
        trivial.do: writer.write it

    if not patch.from_: return

    // Attempt to fetch the old trivial patch and use it to construct
    // the old bits so we can compute a diff from them.
    old-id := id --to=patch.from_
    cache-key = cache-key-patch
        --broker-config=server-config_
        --organization-id=organization-id_
        --patch-id=old-id
    trivial-old := cli_.cache.get cache-key: | store/FileStore |
      downloaded := null
      catch: downloaded = broker-connection_.download-firmware
          --organization-id=organization-id_
          --id=old-id
      if not downloaded:
        cli_.ui.emit --warning "Failed to download old firmware for patch $old-id -> $trivial-id."
        return
      store.with-tmp-directory: | tmp-dir |
        file.write-contents downloaded --path="$tmp-dir/patch"
        // TODO(florian): we don't have the chunk-size when downloading from the broker.
        store.move "$tmp-dir/patch"

    bitstream := io.Reader trivial-old
    patcher := Patcher bitstream null
    patch-writer := PatchWriter
    if not patcher.patch patch-writer: return
    // Build the old bits and check that we get the correct hash.
    old := patch-writer.buffer.bytes
    if old.size < patch-writer.size: old += ByteArray (patch-writer.size - old.size)
    sha := sha256.Sha256
    sha.add old
    if patch.from_ != sha.get: return

    diff-id := id --from=patch.from_ --to=patch.to_
    cache-key = cache-key-patch
        --broker-config=server-config_
        --organization-id=organization-id_
        --patch-id=diff-id
    cli_.cache.get cache-key: | store/FileStore |
      // Build the diff and verify that we can apply it and get the
      // correct hash out before uploading it.
      diff := build-diff-patch old patch.bits_
      if patch.to_ != (compute-applied-hash diff old): return
      diff-size-bytes := diff.reduce --initial=0: | size chunk | size + chunk.size
      diff-size := diff-size-bytes > 4096
          ? "$((diff-size-bytes + 1023) / 1024) KB"
          : "$diff-size-bytes B"
      from64 := base64.encode patch.from_ --url-mode
      to64 := base64.encode patch.to_ --url-mode
      cli_.ui.emit --info "Uploading patch $from64 -> $to64 ($diff-size)."
      broker-connection_.upload-firmware diff
          --organization-id=organization-id_
          --firmware-id=diff-id
      store.save-via-writer: | writer/io.Writer |
        diff.do: writer.write it

  /**
  Computes the patch identifier for a (from, to) firmware checksum pair.

  If $from is null, returns the trivial-patch identifier for $to.
  */
  static id --from/ByteArray?=null --to/ByteArray -> string:
    folder := base64.encode to --url-mode
    entry := from ? (base64.encode from --url-mode) : "none"
    return "$folder/$entry"

  /**
  Applies $diff to $old and returns the SHA-256 of the result.

  Returns null if the diff doesn't apply cleanly.
  */
  static compute-applied-hash diff/List old/ByteArray -> ByteArray?:
    combined := diff.reduce --initial=#[]: | acc chunk | acc + chunk
    bitstream := io.Reader combined
    patcher := Patcher bitstream old
    writer := PatchWriter
    if not patcher.patch writer: return null
    sha := sha256.Sha256
    sha.add writer.buffer.bytes
    return sha.get
