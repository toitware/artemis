// Copyright (C) 2020 Toitware ApS. All rights reserved.

import bytes

import .binary_diff
import ...shared.utils.patch
import ...shared.utils.patch_format

// Chunk the new image into 16k sizes (uncompressed).  These are the points
// where we can resume an incremental update.
SUBCHUNK_SIZE := 16 * 1024

build_diff_patch old_bytes/ByteArray new_bytes/ByteArray -> List:
  old_data := OldData old_bytes
  chunks := []
  total_new_size := new_bytes.size
  List.chunk_up 0 total_new_size SUBCHUNK_SIZE: | from to |
    writer := bytes.Buffer
    diff old_data new_bytes[from..to] writer total_new_size
        --fast=false
        --with_header=(from == 0)
        --with_footer=(to == total_new_size)
    chunks.add writer.bytes
  return chunks

build_trivial_patch new_bytes/ByteArray -> List:
  chunks := []
  total_new_size := new_bytes.size
  List.chunk_up 0 total_new_size SUBCHUNK_SIZE: | from to |
    writer := bytes.Buffer
    literal_block
        new_bytes[from..to]
        writer
        --total_new_bytes=(from == 0 ? total_new_size : null)
        --with_footer=(to == total_new_size)
    chunks.add writer.bytes
  return chunks
