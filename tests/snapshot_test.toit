// Copyright (C) 2023 Toitware ApS.

import ar
import bytes
import expect show *
import host.file
import snapshot show cache_snapshot
import uuid
import .utils

main:
  random_uuid := uuid.uuid5 "snapshot_test" "random $Time.monotonic_us $random"

  buffer := bytes.Buffer
  writer := ar.ArWriter buffer
  writer.add "uuid" random_uuid.to_byte_array

  fake_snapshot := buffer.bytes

  with_tmp_directory: | tmp_dir/string |
    out_dir := "$tmp_dir/multi/dirs"
    cache_snapshot --output_directory=out_dir fake_snapshot

    expect (file.is_file "$out_dir/$(random_uuid.stringify).snapshot")
