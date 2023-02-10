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

import .brokers.broker
import ..shared.utils.patch

firmware_update logger/log.Logger resources/ResourceManager --old/string --new/string -> none:
  old_firmware := Firmware.encoded old
  new_firmware := Firmware.encoded new

  // If we have a checkpoint for a different firmware update, we
  // clear it out and start over.
  checkpoint := Checkpoint.fetch
  if checkpoint and checkpoint.checksum != new_firmware.checksum:
    Checkpoint.clear
    checkpoint = null

  logger.info "firmware update" --tags={"size": new_firmware.size}
  elapsed := Duration.of:
    firmware.map: | old_mapping/firmware.FirmwareMapping? |
      index := checkpoint ? checkpoint.read_part_index : 0
      read_offset := checkpoint ? checkpoint.read_offset : 0
      patcher := FirmwarePatcher_ logger old_mapping
          --checkpoint=checkpoint
          --new=new_firmware
          --old=old_firmware
      try:
        while index < new_firmware.parts.size:
          patcher.write_part resources index read_offset
          read_offset = 0
          index++
        patcher.write_checksum
      finally:
        patcher.close
  logger.info "firmware update: 100%" --tags={"elapsed": elapsed}

class FirmwarePatcher_ implements PatchObserver:
  logger_/log.Logger
  new_/Firmware
  old_/Firmware
  old_mapping_/firmware.FirmwareMapping?

  // Bookkeeping for firmware writing.
  writer_/firmware.FirmwareWriter? := null
  write_skip_/int := 0
  write_offset_/int := 0
  write_offset_next_print_/int := 0

  // Checkpoint handling.
  last_checkpoint_/Checkpoint? := null  // Cache to avoid reading from flash too often.
  next_checkpoint_/Checkpoint? := null
  next_checkpoint_part_index_/int? := null

  constructor .logger_ .old_mapping_ --checkpoint/Checkpoint? --new/Firmware --old/Firmware:
    old_ = old
    new_ = new
    reposition_ checkpoint

  reposition_ checkpoint/Checkpoint? -> int:
    if writer_: writer_.close
    write_skip := checkpoint ? checkpoint.write_skip : 0
    write_offset := checkpoint ? checkpoint.write_offset : 0
    write_skip_ = write_skip
    write_offset_ = write_offset - write_skip  // We haven't written the skipped part yet.
    writer_ = firmware.FirmwareWriter write_offset new_.size
    return checkpoint ? checkpoint.read_offset : 0

  write_part resources/ResourceManager index/int read_offset/int -> none:
    next_checkpoint_part_index_ = index
    try:
      part/Map := new_.parts[index]
      type := part.get "type"
      if type == "config":
        assert: read_offset == 0
        write_device_specific_ part new_.device_specific_encoded
      else:
        // TODO(kasper): Find the old part based on name/type, not index.
        write_patched_ resources read_offset --new=part --old=old_.parts[index]
    finally:
      next_checkpoint_part_index_ = null

  write_checksum -> none:
    on_write new_.checksum
    writer_.commit
    Checkpoint.clear

  write_device_specific_ part/Map device_specific/ByteArray -> none:
    padded_size := part["to"] - part["from"]
    size := ByteArray 4
    LITTLE_ENDIAN.put_uint32 size 0 device_specific.size
    on_write size
    on_write device_specific
    pad_ padded_size - (device_specific.size + 4)

  write_patched_ resources/ResourceManager read_offset/int --new/Map --old/Map -> none:
    new_hash := new["hash"]
    old_hash := old["hash"]

    old_mapping/firmware.FirmwareMapping? := null
    if old_mapping_:
      old_from := old["from"]
      old_to := old["to"]
      old_mapping = old_mapping_[old_from..old_to]

    if old_mapping and new_hash == old_hash:
      assert: read_offset == 0
      chunk := ByteArray 512
      List.chunk_up 0 old_mapping.size chunk.size: | from to size |
        old_mapping.copy from to --into=chunk
        on_write chunk[0..size]
      return

    new_id := base64.encode new_hash --url_mode
    resource_urls := []
    if old_mapping:
      old_id := base64.encode old_hash --url_mode
      resource_urls.add "$new_id/$old_id"

    // We might not find the old->new patch. Use the 'none' patch as a fallback.
    resource_urls.add "$new_id/none"

    for i := 0; i < resource_urls.size; i++:
      resource_url := resource_urls[i]
      exception := catch --unwind=(i == resource_urls.size - 1):
        resources.fetch_firmware resource_url --offset=read_offset:
          | reader/SizedReader offset/int |
            continuation := apply_ reader offset old_mapping
            if not continuation: return
            reposition_ continuation  // Returns the read offset to continue from.
      if not exception: return
      logger_.warn "firmware update: failed to fetch patch"
          --tags={"url": resource_url, "error": exception}

  apply_ reader/SizedReader offset/int old_mapping/firmware.FirmwareMapping? -> Checkpoint?:
    binary_patcher := Patcher reader old_mapping --patch_offset=offset
    try:
      last_checkpoint_ = null
      binary_patcher.patch this
    finally: | is_exception exception |
      last := last_checkpoint_
      last_checkpoint_ = null
      // If the patching finished, we're done and return null to indicate that.
      if not is_exception: return null
      // This is an optimization. We avoid leaving the firmware fetching loop
      // in $ResourceManager.fetch_firmware so we can reuse the client and
      // avoid resynchronizing before resuming the patching.
      if last and exception.value == UNEXPECTED_END_OF_READER_EXCEPTION: return last
    unreachable

  pad_ padding/int -> none:
    write_ 0 padding: | x y | writer_.pad (y - x)

  on_write data from/int=0 to/int=data.size -> none:
    write_ from to: | x y | writer_.write data[x..y]

  write_ from/int to/int [write] -> none:
    // Skip over already written parts.
    if write_skip_ > 0:
      size := min write_skip_ (to - from)
      write_skip_ -= size
      write_offset_ += size
      if write_skip_ > 0: return
      from += size

    // Try to get to a checkpoint by writing out the parts
    // leading up to the checkpoint. If we get all the way
    // to the checkpoint write offset, we've reached the
    // checkpoint and we can commit it to flash.
    if next_checkpoint_:
      checkpoint_write_offset := next_checkpoint_.write_offset
      size := min (checkpoint_write_offset - write_offset_) (to - from)
      write.call from (from + size)
      write_offset_ += size
      if write_offset_ < checkpoint_write_offset: return
      commit_checkpoint_
      from += size

    // Write the rest.
    write.call from to
    write_offset_ += to - from

    // Give us some nice progress tracking.
    if write_offset_ > write_offset_next_print_:
      percent := (write_offset_ * 100) / new_.size
      logger_.info "firmware update: $(%3d percent)%"
      write_offset_next_print_ = write_offset_ + 64 * 1024

  on_new_checksum hash/ByteArray -> none:
    // Not used anymore.
    unreachable

  on_size size/int -> none:
    // Do nothing.

  on_checkpoint read_offset/int -> none:
    if next_checkpoint_: return
    current_write_offset := write_offset_
    checkpoint_write_offset := round_up current_write_offset 16
    write_skip := checkpoint_write_offset - current_write_offset
    next_checkpoint_ = Checkpoint
        new_.checksum
        --read_part_index=next_checkpoint_part_index_
        --read_offset=read_offset
        --write_offset=checkpoint_write_offset
        --write_skip=write_skip
    if write_skip == 0: commit_checkpoint_

  close -> none:
    if not writer_: return
    writer_.close
    writer_ = null

  commit_checkpoint_ -> none:
    writer_.flush
    next := next_checkpoint_
    Checkpoint.update next
    last_checkpoint_ = next
    next_checkpoint_ = null

class Firmware:
  size/int
  parts/List
  device_specific_encoded/ByteArray
  checksum/ByteArray

  constructor.encoded encoded/string:
    decoded := ubjson.decode (base64.decode encoded)
    device_specific_encoded = decoded["device-specific"]
    device_specific := ubjson.decode device_specific_encoded
    parts = ubjson.decode device_specific["parts"]
    checksum = decoded["checksum"]
    size = parts.last["to"] + checksum.size

class Checkpoint:
  // TODO(kasper): For now, we just store the checkpoint in
  // a variable. We should put it in flash or RTC memory.
  static stored_ / Checkpoint? := null

  // TODO(kasper): The checksum currently only covers the
  // target image under the assumption that we're going to
  // clear the checkpoint information stored in flash on
  // upgrades. This might be a poor decision and it could
  // make sense to also include the checksum of the firmware
  // we're upgrading from.
  checksum/ByteArray

  // How far did we get in reading the structured description
  // of the target firmware?
  read_part_index/int
  read_offset/int

  // How far did we get in writing the bits of the target
  // firmware out to flash?
  write_offset/int
  write_skip/int

  constructor .checksum --.read_part_index --.read_offset --.write_offset --.write_skip:

  static fetch -> Checkpoint?:
    return stored_

  static update checkpoint/Checkpoint? -> none:
    stored_ = checkpoint

  static clear -> none:
    stored_ = null
