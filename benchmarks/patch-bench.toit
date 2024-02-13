// Copyright (C) 2023 Toitware ApS. All rights reserved.

import binary show LITTLE-ENDIAN
import bytes show Buffer Reader
import expect show *
import host.file

import artemis.cli.utils.binary-diff show *
import artemis.shared.utils.patch show *

main:
  bench "-a" FAST 50000
  bench "-a" TWO-PHASE 50000
  bench "-a" SLOW 50000
  bench "-b" FAST 100000
  bench "-b" TWO-PHASE 100000
  bench "-b" SLOW 100000

bench suffix/string algorithm/int size/int:
  old := file.read-content "benchmarks/old$(suffix).bin"
  new := file.read-content "benchmarks/new$(suffix).bin"
  old = old[..size] + old[old.size - size..]
  new = new[..size] + new[new.size - size..]
  old-data := OldData old 0 0
  writer := Buffer
  diff-time := Duration.of:
    diff
        old-data
        new
        writer
        new.size
        --algorithm=algorithm
        --with-header=true
        --with-footer=true
        --with-checksums=false
  result := writer.bytes

  print ""
  print "Algorithm: $algorithm"
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
