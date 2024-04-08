// Copyright (C) 2023 Toitware ApS. All rights reserved.

import expect show *
import host.file
import io
import io show LITTLE-ENDIAN

import artemis.cli.utils.binary-diff show *
import artemis.shared.utils.patch show *

main:
  bench "-a" true 50000
  bench "-a" false 50000
  bench "-b" true 100000
  bench "-b" false 100000

bench suffix/string fast/bool size/int:
  old := file.read-content "benchmarks/old$(suffix).bin"
  new := file.read-content "benchmarks/new$(suffix).bin"
  old = old[..size] + old[old.size - size..]
  new = new[..size] + new[new.size - size..]
  old-data := OldData old 0 0
  writer := io.Buffer
  diff-time := Duration.of:
    diff
        old-data
        new
        writer
        new.size
        --fast=fast
        --with-header=true
        --with-footer=true
        --with-checksums=false
  result := writer.bytes

  print ""
  print "Algorithm: $(fast ? "fast" : "slow")"
  print "Diff size for $(new.size >> 10)kB: $result.size bytes"

  test-writer := TestWriter
  patcher := Patcher
      io.Reader result
      old

  patch-time := Duration.of:
    patcher.patch test-writer

  print "Diffed  in $diff-time"
  print "Patched in $patch-time"

class TestWriter implements PatchObserver:
  size /int? := null
  writer /io.Buffer := io.Buffer

  on-write data from/int=0 to/int=data.size:
    writer.write data[from..to]

  on-size size/int: this.size = size

  on-new-checksum checksum/ByteArray:

  on-checkpoint patch-position/int:
