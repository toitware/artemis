// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import system.firmware
import system.trace show send-trace-message

import io
import io show LITTLE-ENDIAN

import .brokers.broker
import .device
import .firmware
import ..shared.utils.patch

/**
Updates the firmware for the $device to match the encoded firmware
  specified by the $new string.
*/
firmware-update logger/log.Logger broker-connection/BrokerConnection -> none
    --device/Device
    --new/string:
  old-firmware := Firmware.encoded device.firmware
  new-firmware := Firmware.encoded new
  checkpoint := device.checkpoint --old=old-firmware --new=new-firmware

  logger.info "firmware update" --tags={"size": new-firmware.size}
  elapsed := Duration.of:
    firmware.map: | old-mapping/firmware.FirmwareMapping? |
      index := checkpoint ? checkpoint.read-part-index : 0
      read-offset := checkpoint ? checkpoint.read-offset : 0
      patcher := FirmwarePatcher_ logger old-mapping
          --device=device
          --checkpoint=checkpoint
          --new=new-firmware
          --old=old-firmware
      try:
        while index < new-firmware.parts.size:
          patcher.write-part broker-connection index read-offset
          read-offset = 0
          index++
        patcher.write-checksum
      finally: | is-exception exception |
        patcher.close
        if is-exception:
          // We only keep the last checkpoint if we get a specific
          // recognizable error from reading the patch. The intent
          // is to use checkpoints exclusively for loss of power
          // and network. For all other exceptions, we assume that
          // we may have gotten a corrupt patch or written to the
          // flash in an incorrect way, so we prefer not catching
          // such exceptions.
          if PATCH-READING-FAILED-EXCEPTION == exception.value:
            logger.warn "firmware update: interrupted due to network error"
          else:
            // Got an unexpected exception. Be careful and clear the
            // checkpoint information and let the exception continue
            // unwinding the stack.
            device.checkpoint-update null
            // Use the low-level tracing support to help diagnose
            // the cause of the non-network exceptions we get. We
            // do not clear the trace in the exception, like we
            // do in the catch: implementation, so we may get into
            // a situation where it is reported more than once.
            trace := exception.trace
            if trace: send-trace-message trace
            logger.warn "firmware update: abandoned due to non-network error"
  logger.info "firmware update: 100%" --tags={"elapsed": elapsed}

class FirmwarePatcher_ implements PatchObserver:
  logger_/log.Logger
  device_/Device
  new_/Firmware
  old_/Firmware
  old-mapping_/firmware.FirmwareMapping?

  // Bookkeeping for firmware writing.
  writer_/firmware.FirmwareWriter? := null
  write-skip_/int := 0
  write-offset_/int := 0
  write-offset-next-print_/int := 0

  // Checkpoint handling.
  next-checkpoint_/Checkpoint? := null
  next-checkpoint-part-index_/int? := null

  constructor .logger_ .old-mapping_
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
    write-skip := checkpoint ? checkpoint.write-skip : 0
    write-offset := checkpoint ? checkpoint.write-offset : 0
    write-skip_ = write-skip
    write-offset_ = write-offset - write-skip  // We haven't written the skipped part yet.
    writer_ = firmware.FirmwareWriter write-offset new_.size
    return checkpoint ? checkpoint.read-offset : 0

  write-part broker-connection/BrokerConnection index/int read-offset/int -> none:
    next-checkpoint_ = null
    next-checkpoint-part-index_ = index
    try:
      part/Map := new_.parts[index]
      type := part.get "type"
      if type == "config":
        assert: read-offset == 0
        write-device-specific_ part new_.device-specific-encoded
      else:
        // TODO(kasper): Find the old part based on name/type, not index.
        write-patched_ broker-connection read-offset --new=part --old=old_.parts[index]
    finally:
      next-checkpoint-part-index_ = null

  write-checksum -> none:
    on-write new_.checksum
    writer_.commit

  write-device-specific_ part/Map device-specific/ByteArray -> none:
    padded-size := part["to"] - part["from"]
    size := ByteArray 4
    LITTLE-ENDIAN.put-uint32 size 0 device-specific.size
    on-write size
    on-write device-specific
    pad_ padded-size - (device-specific.size + 4)

  write-patched_ broker-connection/BrokerConnection read-offset/int --new/Map --old/Map -> none:
    new-hash/ByteArray := new["hash"]
    old-hash/ByteArray := old["hash"]

    old-mapping/firmware.FirmwareMapping? := null
    if old-mapping_:
      old-from := old["from"]
      old-to := old["to"]
      old-mapping = old-mapping_[old-from..old-to]

    if old-mapping and new-hash == old-hash:
      // We do not currently use checkpoints for copied parts, so
      // this should always be started from offset zero.
      assert: read-offset == 0
      copy_ old-mapping
      return

    new-id := Firmware.id --hash=new-hash
    resource-urls := []
    if old-mapping:
      old-id := Firmware.id --hash=old-hash
      resource-urls.add "$new-id/$old-id"

    // We might not find the old->new patch. Use the 'none' patch as
    // a fallback. We try this if we fail to fetch and thus never
    // start applying the patch version.
    resource-urls.add "$new-id/none"

    resource-urls.do: | resource-url/string |
      // If we get an exception before we start applying the patch,
      // we continue to the next resource URL in the list. Notice
      // how the 'unwind' argument is a block to get lazy evaluation
      // so we can update 'started_applying' from within the block
      // passed to 'fetch_firmware'.
      started-applying := false
      exception := catch --unwind=(: started-applying):
        broker-connection.fetch-firmware resource-url --offset=read-offset:
          | reader/io.Reader offset/int |
            started-applying = true
            apply_ reader offset old-mapping
        // If we get here, we expect that we have started applying
        // the patch. Getting here without having started applying
        // the patch indicates that fetching the firmware neither
        // threw nor invoked the block, which shouldn't happen,
        // but to be safe we check anyway.
        if started-applying: return
      // We didn't start applying the patch, so we conclude that
      // we failed fetching it. If there are more possible URLs
      // to fetch from, we try the next.
      logger_.warn "firmware update: failed to fetch patch" --tags={
        "url": resource-url,
        "error": exception
      }

    // We never got started applying any of the patches, so we conclude
    // that we were unable to read the patch.
    throw PATCH-READING-FAILED-EXCEPTION

  apply_ reader/io.Reader offset/int old-mapping/firmware.FirmwareMapping? -> none:
    binary-patcher := Patcher reader old-mapping --patch-offset=offset
    if not binary-patcher.patch this:
      // This should only happen if we to get the wrong bits
      // served to us. It is unlikely, but we log it and throw
      // an exception so we can try to recover.
      logger_.error "firmware update: failed to apply patch"
      throw "INVALID_FORMAT"

  pad_ padding/int -> none:
    write_ 0 padding: | x y | writer_.pad (y - x)

  copy_ mapping/firmware.FirmwareMapping -> none:
    writer_.copy mapping: | size/int |
      write-offset_ += size
      on-progress_

  on-write data from/int=0 to/int=data.size -> none:
    write_ from to: | x y | writer_.write data[x..y]

  write_ from/int to/int [write] -> none:
    // Skip over already written parts.
    if write-skip_ > 0:
      size := min write-skip_ (to - from)
      write-skip_ -= size
      write-offset_ += size
      if write-skip_ > 0: return
      from += size

    // Try to get to a checkpoint by writing out the parts
    // leading up to the checkpoint. If we get all the way
    // to the checkpoint write offset, we've reached the
    // checkpoint and we can commit it to flash.
    if next-checkpoint_:
      checkpoint-write-offset := next-checkpoint_.write-offset
      size := min (checkpoint-write-offset - write-offset_) (to - from)
      write.call from (from + size)
      write-offset_ += size
      if write-offset_ < checkpoint-write-offset: return
      commit-checkpoint_
      from += size

    // Write the rest.
    write.call from to
    write-offset_ += to - from
    on-progress_

  on-new-checksum hash/ByteArray -> none:
    // Not used anymore.
    unreachable

  on-size size/int -> none:
    // Do nothing.

  on-checkpoint read-offset/int -> none:
    if next-checkpoint_: return
    current-write-offset := write-offset_
    checkpoint-write-offset := round-up current-write-offset 16
    write-skip := checkpoint-write-offset - current-write-offset
    next-checkpoint_ = Checkpoint
        --old-checksum=old_.checksum
        --new-checksum=new_.checksum
        --read-part-index=next-checkpoint-part-index_
        --read-offset=read-offset
        --write-offset=checkpoint-write-offset
        --write-skip=write-skip
    if write-skip == 0: commit-checkpoint_

  on-progress_ -> none:
    if write-offset_ <= write-offset-next-print_: return
    percent := (write-offset_ * 100) / new_.size
    logger_.info "firmware update: $(%3d percent)%"
    write-offset-next-print_ = write-offset_ + 64 * 1024

  close -> none:
    if not writer_: return
    writer_.close
    writer_ = null

  commit-checkpoint_ -> none:
    writer_.flush
    next := next-checkpoint_
    device_.checkpoint-update next
    next-checkpoint_ = null
