// Copyright (C) 2023 Toitware ApS. All rights reserved.

import host.file

write-blob-to-file path/string value -> none:
  stream := file.Stream.for-write path
  try:
    stream.out.write value
  finally:
    stream.close
