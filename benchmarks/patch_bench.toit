// Copyright (C) 2023 Toitware ApS. All rights reserved.

import binary show LITTLE_ENDIAN
import bytes show Buffer Reader
import expect show *
import host.file

import artemis.cli.utils.binary_diff show *
import artemis.shared.utils.patch show *

main:
  old := file.read_content "benchmarks/old.bin"
  new := file.read_content "benchmarks/new.bin"
  old = old[..50000] + old[old.size - 50000..]
  new = new[..50000] + new[new.size - 50000..]
  old_data := OldData old 0 0
  writer := Buffer
  diff_time := Duration.of:
    diff
        old_data
        new
        writer
        new.size
        --fast=false
        --with_header=true
        --with_footer=true
        --with_checksums=false
  result := writer.bytes

  print "Diff size for $(new.size >> 10)kB: $result.size bytes"

  test_writer := TestWriter
  patcher := Patcher
      Reader result
      old

  patch_time := Duration.of:
    patcher.patch test_writer

  print "Diffed  in $diff_time"
  print "Patched in $patch_time"



class TestWriter implements PatchObserver:
  size /int? := null
  writer /Buffer := Buffer

  on_write data from/int=0 to/int=data.size:
    writer.write data[from..to]

  on_size size/int: this.size = size

  on_new_checksum checksum/ByteArray:

  on_checkpoint patch_position/int:
