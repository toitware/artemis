// Copyright (C) 2020 Toitware ApS. All rights reserved.

import host.file
import ..kernel.config
import encoding.tpack as tpack
import encoding.json as json
import services.arguments show *
import crypto.sha256 as crypto
import bytes
import host.pipe
import writer
import uuid

/**
  usage: encode_config
*/
main args/List:
  buffer := bytes.Buffer
  while data := pipe.stdin.read:
    buffer.write data

  m := (json.Decoder).decode buffer.bytes

  cfg := parse_config m
  stdout := writer.Writer pipe.stdout
  stdout.write
    encode_config cfg

encode_config config/Config -> ByteArray:
  return tpack.encode config
