// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import system.firmware

import binary show LITTLE_ENDIAN
import encoding.ubjson
import reader show Reader
import uuid

import .brokers.broker
import .brokers.http
import .device
import .firmware
import ..shared.utils.patch

/**
Updates the firmware for the $device to match the encoded firmware
  specified by the $new string.
*/
firmware_update logger/log.Logger broker_connection/BrokerConnection -> none
    --device/Device
    --new/string:
  old_firmware := Firmware.encoded device.firmware
  new_firmware := Firmware.encoded new
  checkpoint := device.checkpoint --old=old_firmware --new=new_firmware

  logger.info "firmware update" --tags={"size": new_firmware.size}
  elapsed := Duration.of:
    firmware.map: | old_mapping/firmware.FirmwareMapping? |
      index := checkpoint ? checkpoint.read_part_index : 0
      read_offset := checkpoint ? checkpoint.read_offset : 0
      patcher := FirmwarePatcher_ logger old_mapping
          --device=device
          --checkpoint=checkpoint
          --new=new_firmware
          --old=old_firmware
      try:
        while index < new_firmware.parts.size:
          patcher.write_part broker_connection index read_offset
          read_offset = 0
          index++
        patcher.write_checksum
      finally: | is_exception exception |
        patcher.close
        if is_exception:
          // We only keep the last checkpoint if we get a specific
          // recognizable error from reading the patch. The intent
          // is to use checkpoints exclusively for loss of power
          // and network. For all other exceptions, we assume that
          // we may have gotten a corrupt patch or written to the
          // flash in an incorrect way, so we prefer not catching
          // such exceptions.
          if PATCH_READING_FAILED_EXCEPTION == exception.value:
            logger.warn "firmware update: interrupted due to network error"
          else:
            // Got an unexpected exception. Be careful and clear the
            // checkpoint information and let the exception continue
            // unwinding the stack.
            device.checkpoint_update null
            logger.warn "firmware update: abandoned due to non-network error"
  logger.info "firmware update: 100%" --tags={"elapsed": elapsed}

class FirmwarePatcher_ implements PatchObserver:
  logger_/log.Logger
  device_/Device
  new_/Firmware
  old_/Firmware
  old_mapping_/firmware.FirmwareMapping?

  // Bookkeeping for firmware writing.
  writer_/firmware.FirmwareWriter? := null
  write_skip_/int := 0
  write_offset_/int := 0
  write_offset_next_print_/int := 0

  // Checkpoint handling.
  next_checkpoint_/Checkpoint? := null
  next_checkpoint_part_index_/int? := null

  constructor .logger_ .old_mapping_
      --device/Device
      --checkpoint/Checkpoint?
      --new/Firmware
      --old/Firmware:
    device_ = device
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

  write_part broker_connection/BrokerConnection index/int read_offset/int -> none:
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
        write_patched_ broker_connection read_offset --new=part --old=old_.parts[index]
    finally:
      next_checkpoint_part_index_ = null

  write_checksum -> none:
    on_write new_.checksum
    writer_.commit

  write_device_specific_ part/Map device_specific/ByteArray -> none:
    padded_size := part["to"] - part["from"]
    size := ByteArray 4
    LITTLE_ENDIAN.put_uint32 size 0 device_specific.size
    on_write size
    on_write device_specific
    pad_ padded_size - (device_specific.size + 4)

  write_patched_ broker_connection/BrokerConnection read_offset/int --new/Map --old/Map -> none:
    new_hash/ByteArray := new["hash"]
    old_hash/ByteArray := old["hash"]

    old_mapping/firmware.FirmwareMapping? := null
    if old_mapping_:
      old_from := old["from"]
      old_to := old["to"]
      old_mapping = old_mapping_[old_from..old_to]

    if old_mapping and new_hash == old_hash:
      // We do not currently use checkpoints for copied parts, so
      // this should always be started from offset zero.
      assert: read_offset == 0
      copy_ old_mapping
      return

    new_id := Firmware.id --hash=new_hash
    resource_urls := []
    if old_mapping:
      old_id := Firmware.id --hash=old_hash
      resource_urls.add "$new_id/$old_id"

    // We might not find the old->new patch. Use the 'none' patch as
    // a fallback. We try this if we fail to fetch and thus never
    // start applying the patch version.
    resource_urls.add "$new_id/none"

    // During migration the organization-id of the current device isn't correct.
    // We must take it from the target firmware.
    // Normally we are not supposed to extract anything from the target firmware
    // since the format could have changed.
    // However, for migration purposes we know the format and we don't really
    // have any better options.
    device_specific := ubjson.decode new_.device_specific_encoded
    new_org := uuid.parse device_specific["artemis.device"]["organization_id"]

    resource_urls.do: | resource_url/string |
      // If we get an exception before we start applying the patch,
      // we continue to the next resource URL in the list. Notice
      // how the 'unwind' argument is a block to get lazy evaluation
      // so we can update 'started_applying' from within the block
      // passed to 'fetch_firmware'.
      started_applying := false
      exception := catch --unwind=(: started_applying):
        http_connection := broker_connection as BrokerConnectionHttp
        http_connection.fetch_firmware resource_url
            --organization_id=new_org
            --offset=read_offset:
          | reader/Reader offset/int |
            started_applying = true
            apply_ reader offset old_mapping
        // If we get here, we expect that we have started applying
        // the patch. Getting here without having started applying
        // the patch indicates that fetching the firmware neither
        // threw nor invoked the block, which shouldn't happen,
        // but to be safe we check anyway.
        if started_applying: return
      // We didn't start applying the patch, so we conclude that
      // we failed fetching it. If there are more possible URLs
      // to fetch from, we try the next.
      logger_.warn "firmware update: failed to fetch patch" --tags={
        "url": resource_url,
        "error": exception
      }

    // We never got started applying any of the patches, so we conclude
    // that we were unable to read the patch.
    throw PATCH_READING_FAILED_EXCEPTION

  apply_ reader/Reader offset/int old_mapping/firmware.FirmwareMapping? -> none:
    binary_patcher := Patcher reader old_mapping --patch_offset=offset
    if not binary_patcher.patch this:
      // This should only happen if we to get the wrong bits
      // served to us. It is unlikely, but we log it and throw
      // an exception so we can try to recover.
      logger_.error "firmware update: failed to apply patch"
      throw "INVALID_FORMAT"

  pad_ padding/int -> none:
    write_ 0 padding: | x y | writer_.pad (y - x)

  copy_ mapping/firmware.FirmwareMapping -> none:
    writer_.copy mapping: | size/int |
      write_offset_ += size
      on_progress_

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
    on_progress_

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

  on_progress_ -> none:
    if write_offset_ <= write_offset_next_print_: return
    percent := (write_offset_ * 100) / new_.size
    logger_.info "firmware update: $(%3d percent)%"
    write_offset_next_print_ = write_offset_ + 64 * 1024

  close -> none:
    if not writer_: return
    writer_.close
    writer_ = null

  commit_checkpoint_ -> none:
    writer_.flush
    next := next_checkpoint_
    device_.checkpoint_update next
    next_checkpoint_ = null
