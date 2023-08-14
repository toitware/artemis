// Copyright (C) 2023 Toitware ApS. All rights reserved.

import host.file
import writer

write-blob-to-file path/string value -> none:
  stream := file.Stream.for-write path
  try:
    writer := writer.Writer stream
    writer.write value
  finally:
    stream.close
