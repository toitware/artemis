// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import bytes
import esp32
import crypto.sha256
import system.firmware
import system.storage
import encoding.ubjson
import encoding.base64

import binary show LITTLE_ENDIAN
import reader show SizedReader UNEXPECTED_END_OF_READER_EXCEPTION

import .brokers.broker
import ..shared.utils.patch

firmware_update -> none
    logger/log.Logger
    resources/ResourceManager
    --organization_id/string
    --old/string
    --new/string:
  old_firmware := Firmware.encoded old
  new_firmware := Firmware.encoded new
  checkpoint := Checkpoint.fetch --old=old_firmware --new=new_firmware

  // TODO(kasper): We need some kind of mechanism to get out of
  // trouble if our checkpointing information is wrong. Can we
  // recognize all the exceptions that could indicate that we
  // should start over?

  logger.info "firmware update" --tags={"size": new_firmware.size}
  elapsed := Duration.of:
    firmware.map: | old_mapping/firmware.FirmwareMapping? |
      index := checkpoint ? checkpoint.read_part_index : 0
      read_offset := checkpoint ? checkpoint.read_offset : 0
      patcher := FirmwarePatcher_ logger old_mapping
          --organization_id=organization_id
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
  organization_id_/string
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

  constructor .logger_ .old_mapping_
      --organization_id/string
      --checkpoint/Checkpoint?
      --new/Firmware
      --old/Firmware:
    organization_id_ = organization_id
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
    next_checkpoint_ = null
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
    try:
      // If we get to a point where we are ready to commit, we
      // make sure to always clear the checkpoint, so that any
      // problems arising from this leads to starting over.
      writer_.commit
    finally:
      // TODO(kasper): Maybe we can do this clearing in a more
      // general location, so that everything that looks like
      // it impossible to make progress from starts over?
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
      // We do not currently use checkpoints for copied parts, so
      // this should always be started from offset zero.
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
      started_applying := false
      exception := catch --unwind=(started_applying or i == resource_urls.size - 1):
        resources.fetch_firmware resource_url
            --organization_id=organization_id_
            --offset=read_offset:
          | reader/SizedReader offset/int |
            started_applying = true
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
      if not binary_patcher.patch this:
        // TODO(kasper): Maybe we can do this clearing in a more
        // general location, so that everything that looks like
        // it impossible to make progress from starts over?
        Checkpoint.clear
        // This should only happen if we to get the wrong bits
        // served to us. It is unlikely, but we log it and throw
        // an exception so we can try to recover.
        logger_.error "firmware update: failed to apply patch"
        throw "INVALID_FORMAT"
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
        --old_checksum=old_.checksum
        --new_checksum=new_.checksum
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
  static KEY ::= "checkpoint"

  // We store the checkpoint in flash, which means
  // that we can use it across a power loss.
  static bucket_ := storage.Bucket.open --flash "toit.io/artemis/checkpoint"

  // We keep the checksums for the new and the old firmware
  // around, so we can validate if a stored checkpoint is
  // intended for a specific firmware update.
  old_checksum/ByteArray
  new_checksum/ByteArray

  // How far did we get in reading the structured description
  // of the target firmware?
  read_part_index/int
  read_offset/int

  // How far did we get in writing the bits of the target
  // firmware out to flash?
  write_offset/int
  write_skip/int

  constructor
      --.old_checksum
      --.new_checksum
      --.read_part_index
      --.read_offset
      --.write_offset
      --.write_skip:

  static fetch --old/Firmware --new/Firmware -> Checkpoint?:
    list := bucket_.get KEY
    if not (list is List and list.size == 6)
        or old.checksum != list[0]
        or new.checksum != list[1]:
      // If we find an oddly shaped entry in the bucket,
      // we might as well clear it out.
      clear
      return null
    return Checkpoint
        --old_checksum=old.checksum
        --new_checksum=new.checksum
        --read_part_index=list[2]
        --read_offset=list[3]
        --write_offset=list[4]
        --write_skip=list[5]

  static update checkpoint/Checkpoint? -> none:
    if checkpoint:
      bucket_[KEY] = [
        checkpoint.old_checksum,
        checkpoint.new_checksum,
        checkpoint.read_part_index,
        checkpoint.read_offset,
        checkpoint.write_offset,
        checkpoint.write_skip
      ]
    else:
      clear

  static clear -> none:
    bucket_.remove KEY
