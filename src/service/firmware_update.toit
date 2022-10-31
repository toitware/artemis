// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import bytes
import esp32
import crypto.sha256
import system.firmware
import encoding.ubjson
import encoding.base64

import binary show LITTLE_ENDIAN
import reader show SizedReader UNEXPECTED_END_OF_READER_EXCEPTION

import .mediator_service
import ..shared.utils.patch

firmware_update logger/log.Logger resources/ResourceManager --old/string --new/string -> none:
  // TODO(kasper): Introduce run-levels for jobs and make sure we're
  // not running a lot of other stuff while we update the firmware.
  old_firmware := ubjson.decode (base64.decode old)
  old_parts := ubjson.decode (ubjson.decode old_firmware["config"])["parts"]
  new_firmware := ubjson.decode (base64.decode new)
  new_config_encoded := new_firmware["config"]
  new_config := ubjson.decode new_config_encoded
  new_parts := ubjson.decode new_config["parts"]
  new_size := new_parts.last["to"] + new_firmware["checksum"].size

  logger.info "firmware update" --tags={"size": new_size}
  elapsed := Duration.of:
    firmware.map: | old/firmware.FirmwareMapping? |
      patcher := FirmwarePatcher_ logger old new_size
      try:
        new_parts.size.repeat: | index/int |
          part := new_parts[index]
          type := part.get "type"
          if type == "config":
            patcher.write_config part new_config_encoded
          else:
            // TODO(kasper): This should be based on name/type -- not index.
            patcher.write_part part resources old_parts[index]
        patcher.write_checksum new_firmware["checksum"]
      finally:
        patcher.close
  logger.info "firmware update: 100%" --tags={"elapsed": elapsed}

class FirmwarePatcher_ implements PatchObserver:
  logger_/log.Logger
  next_print_offset_/int := 0

  // Old.
  old_/firmware.FirmwareMapping?

  // New.
  writer_/firmware.FirmwareWriter? := ?
  size_/int
  offset_/int := ?
  skip_/int := ?

  // Committed.
  image_offset_checkpointed_/int := 0
  image_skip_checkpointed_/int := 0
  patch_offset_checkpointed_/int := -1

  // Uncommitted.
  remaining_/int := 0
  prepared_patch_offset_/int := -1
  prepared_image_skip_/int := -1

  constructor .logger_ .old_ .size_:
    // TODO(kasper): Properly initialize skip and offset if
    // we're resuming after powerloss or dropped connection.
    offset_ = 0
    skip_ = 0
    writer_ = firmware.FirmwareWriter offset_ size_

  write_config part/Map config/ByteArray -> none:
    padded_size := part["to"] - part["from"]
    size := ByteArray 4
    LITTLE_ENDIAN.put_uint32 size 0 config.size
    on_write size
    on_write config
    pad_ padded_size - (config.size + 4)

  write_checksum checksum/ByteArray -> none:
    on_write checksum
    writer_.commit

  write_part part/Map resources/ResourceManager existing/Map -> none:
    new_hash := part["hash"]
    old_hash := existing["hash"]

    old/firmware.FirmwareMapping? := null
    if old_:
      old_from := existing["from"]
      old_to := existing["to"]
      old = old_[old_from..old_to]

    if old and new_hash == old_hash:
      chunk := ByteArray 512
      List.chunk_up 0 old.size chunk.size: | from to size |
        old.copy from to --into=chunk
        on_write chunk[0..size]
      return

    new_id := base64.encode new_hash --url_mode
    resource := null
    if old:
      old_id := base64.encode old_hash --url_mode
      resource = "$new_id/$old_id"
    else:
      resource = "$new_id/none"

    // Reset the patch state.
    patch_size := 0
    patch_offset_checkpointed_ = 0

    resources.fetch_firmware resource: | reader/SizedReader offset/int total_size/int |
      // TODO(kasper): This isn't very elegant. We need the patch size
      // to determine when we're done with the patch, but we only get
      // it passed on the first block invocation.
      if offset == 0: patch_size = total_size
      apply_ reader old patch_size

  apply_ reader/SizedReader old/firmware.FirmwareMapping? patch_size/int -> int:
    start := patch_offset_checkpointed_
    binary_patcher := Patcher reader old --patch_offset=start
    exception := catch --unwind=(: it != UNEXPECTED_END_OF_READER_EXCEPTION or patch_offset_checkpointed_ == start):
      binary_patcher.patch this
    if not exception: return patch_size

    // Go back to last checkpoint.
    logger_.info "going back to checkpoint" --tags={"offset": image_offset_checkpointed_, "skip": image_skip_checkpointed_}
    remaining_ = 0
    skip_ = image_skip_checkpointed_
    offset_ = image_offset_checkpointed_ - skip_
    writer_.close
    writer_ = firmware.FirmwareWriter image_offset_checkpointed_ size_
    return patch_offset_checkpointed_

  pad_ padding/int -> none:
    write_ 0 padding: | x y | writer_.pad (y - x)

  on_write data from/int=0 to/int=data.size -> none:
    write_ from to: | x y | writer_.write data[x..y]

  write_ from/int to/int [write] -> none:
    // Skip over already written parts.
    to_skip := min skip_ (to - from)
    if to_skip > 0:
      skip_ -= to_skip
      offset_ += to_skip
      if skip_ > 0: return
      from += to_skip

    // Then try to get to a checkpoint.
    to_write := min remaining_ (to - from)
    if to_write > 0:
      write.call from (from + to_write)
      remaining_ -= to_write
      offset_ += to_write
      if remaining_ > 0: return
      commit_checkpoint_
      from += to_write

    // Write the rest.
    write.call from to
    offset_ += to - from

    // Give us some nice progress tracking.
    if offset_ > next_print_offset_:
      percent := (offset_ * 100) / size_
      logger_.info "firmware update: $(%3d percent)%"
      next_print_offset_ = offset_ + 64 * 1024

  on_new_checksum hash/ByteArray -> none:
    unreachable

  on_size size/int -> none:
    // Do nothing.

  on_checkpoint patch_offset/int -> none:
    if skip_ > 0 or remaining_ > 0: return
    prepared_patch_offset_ = patch_offset
    align := offset_ & 0xf
    prepared_image_skip_ = align == 0 ? 0 : 16 - align
    if prepared_image_skip_ == 0:
      commit_checkpoint_
    else:
      remaining_ = prepared_image_skip_

  close -> none:
    if not writer_: return
    writer_.close
    writer_ = null

  commit_checkpoint_ -> none:
    writer_.flush
    image_offset_checkpointed_ = offset_
    patch_offset_checkpointed_ = prepared_patch_offset_
    image_skip_checkpointed_ = prepared_image_skip_
    prepared_patch_offset_ = -1
    prepared_image_skip_ = -1
