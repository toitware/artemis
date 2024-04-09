// Copyright (C) 2020 Toitware ApS. All rights reserved.

import io

import .binary-diff
import ...shared.utils.patch
import ...shared.utils.patch-format

// Chunk the new image into 16k sizes (uncompressed).  These are the points
// where we can resume an incremental update.
SUBCHUNK-SIZE := 16 * 1024

// If we get compressed sizes that are smaller than this, we try to
// diff a larger section, so as to reduce overhead.  Generally, creating
// such small chunks is fairly fast, so the run time penalty isn't too
// bad.
TINY-SUBCHUNK-SIZE := 1 * 1024

build-diff-patch old-bytes/ByteArray new-bytes/ByteArray -> List:
  old-data := OldData old-bytes
  chunks := []
  total-new-size := new-bytes.size
  from := 0
  List.chunk-up 0 total-new-size SUBCHUNK-SIZE: | chunk-from chunk-to |
    assert: chunk-from >= from
    writer := io.Buffer
    diff old-data new-bytes[from..chunk-to] writer total-new-size
        --fast
        --with-header=(from == 0)
        --with-footer=(chunk-to == total-new-size)
    output := writer.bytes
    if output.size > TINY-SUBCHUNK-SIZE or chunk-to == total-new-size:
      chunks.add output
      from = chunk-to
  return chunks

build-trivial-patch new-bytes/ByteArray -> List:
  chunks := []
  total-new-size := new-bytes.size
  List.chunk-up 0 total-new-size SUBCHUNK-SIZE: | from to |
    writer := io.Buffer
    literal-block
        new-bytes[from..to]
        writer
        --total-new-bytes=(from == 0 ? total-new-size : null)
        --with-footer=(to == total-new-size)
    chunks.add writer.bytes
  return chunks
