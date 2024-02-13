// Copyright (C) 2023 Toitware ApS. All rights reserved.

import binary show LITTLE-ENDIAN
import bytes show Buffer Reader
import expect show *
import host.file

import artemis.cli.utils.binary-diff show *
import artemis.shared.utils.patch show *

main:
  old := file.read-content "old.bin"
  new := file.read-content "new.bin"
  old = old[..100000] + old[old.size - 100000..]
  new = new[..100000] + new[new.size - 100000..]
  old-data := OldData old 0 0
  writer := Buffer
  diff-time := Duration.of:
    diff
        old-data
        new
        writer
        new.size
        --algorithm=FAST
        --with-header=true
        --with-footer=true
        --with-checksums=false
  result := writer.bytes

  print "Diff size for $(new.size >> 10)kB: $result.size bytes"

  test-writer := TestWriter
  patcher := Patcher
      Reader result
      old

  patch-time := Duration.of:
    patcher.patch test-writer

  print "Diffed  in $diff-time"
  print "Patched in $patch-time"


class TestWriter implements PatchObserver:
  size /int? := null
  writer /Buffer := Buffer

  on-write data from/int=0 to/int=data.size:
    writer.write data[from..to]

  on-size size/int: this.size = size

  on-new-checksum checksum/ByteArray:

  on-checkpoint patch-position/int:
