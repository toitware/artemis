// Copyright (C) 2020 Toitware ApS. All rights reserved.

import bytes

import .binary_diff
import ...shared.utils.patch
import ...shared.utils.patch_format

// Chunk the new image into 16k sizes (uncompressed).  These are the points
// where we can resume an incremental update.
SUBCHUNK_SIZE := 16 * 1024

// If we get compressed sizes that are smaller than this, we try to
// diff a larger section, so as to reduce overhead.  Generally, creating
// such small chunks is fairly fast, so the run time penalty isn't too
// bad.
TINY_SUBCHUNK_SIZE := 1 * 1024

build_diff_patch old_bytes/ByteArray new_bytes/ByteArray -> List:
  old_data := OldData old_bytes
  chunks := []
  total_new_size := new_bytes.size
  from := 0
  List.chunk_up 0 total_new_size SUBCHUNK_SIZE: | chunk_from chunk_to |
    assert: chunk_from >= from
    writer := bytes.Buffer
    diff old_data new_bytes[from..chunk_to] writer total_new_size
        --fast=false
        --with_header=(from == 0)
        --with_footer=(chunk_to == total_new_size)
    output := writer.bytes
    if output.size > TINY_SUBCHUNK_SIZE or chunk_to == total_new_size:
      chunks.add output
      from = chunk_to
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
