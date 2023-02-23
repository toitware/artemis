// Copyright (C) 2023 Toitware ApS. All rights reserved.

import host.file
import writer

write_blob_to_file path/string value -> none:
  stream := file.Stream.for_write path
  try:
    writer := writer.Writer stream
    writer.write value
  finally:
    stream.close
