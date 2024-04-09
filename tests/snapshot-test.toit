// Copyright (C) 2023 Toitware ApS.

import ar
import expect show *
import host.file
import io
import snapshot show cache-snapshot
import uuid
import .utils

main:
  random-uuid := uuid.uuid5 "snapshot_test" "random $Time.monotonic-us $random"

  buffer := io.Buffer
  writer := ar.ArWriter buffer
  writer.add "uuid" random-uuid.to-byte-array

  fake-snapshot := buffer.bytes

  with-tmp-directory: | tmp-dir/string |
    out-dir := "$tmp-dir/multi/dirs"
    cache-snapshot --output-directory=out-dir fake-snapshot

    expect (file.is-file "$out-dir/$(random-uuid.stringify).snapshot")
