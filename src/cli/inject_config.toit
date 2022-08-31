// Copyright (C) 2020 Toitware ApS. All rights reserved.

import binary show LITTLE_ENDIAN
import bytes
import crypto.sha256 as crypto
import host.file
import ..kernel.config
import .encode_config
import encoding.json as json
import encoding.tpack as tpack
import host.file
import ..kernel.config
import host.pipe
import services.arguments show *
import uuid
import writer

// These two are the current offsets of the config data in the system image.
// We could auto-detect them from the bin file, but they are only used files
// from the current SDK so there's no need.
IMAGE_DATA_SIZE ::= 1024
IMAGE_DATA_OFFSET ::= 296

// This is the offset in old SDKs where there are no magic numbers marking
// the location of the offset data
LEGACY_IMAGE_DATA_SIZE ::= 1024
LEGACY_IMAGE_DATA_OFFSET ::= 69888

IMAGE_DATA_MAGIC_1 := 0x7017da7a
IMAGE_DATA_MAGIC_2 := 0xc09f19

/**
  usage: inject_config <sdk_directory> <model> --unique_id=<uuid>
*/
main args/List:
  parser := ArgumentParser
  parser.add_option "unique_id"
  parsed := parser.parse args
  sdk_dir/string := parsed.rest[0] as string
  model/string := parsed.rest[1] as string
  unique_id/uuid.Uuid? := parsed["unique_id"] ? uuid.parse parsed["unique_id"] : uuid.uuid5 "$random" "$Time.now".to_byte_array

  buffer := bytes.Buffer
  while data := pipe.stdin.read:
    buffer.write data

  m := (json.Decoder).decode buffer.bytes

  cfg := parse_config m
  stdout := writer.Writer pipe.stdout
  stdout.write
    inject_config sdk_dir model cfg unique_id

inject_config sdk_dir/string model/string config/Config unique_id/uuid.Uuid -> ByteArray:
  data := encode_config config
  return inject_config_data sdk_dir model data unique_id

// the factory image contains a "empty" section of 1024 bytes here we encoded the config such that
// the image can run completely independently.
// The function updates the sha256 and XOR checksums to ensure that the image stays valid.
inject_config_data sdk_dir/string model/string config_data/ByteArray unique_id/uuid.Uuid -> ByteArray:
  c := file.read_content "$sdk_dir/model/$(model)/factory.bin"

  image_data_position := get_image_data_position c
  image_data_offset := image_data_position[0]
  image_data_size := image_data_position[1]
  image_config_size := image_data_size - uuid.SIZE

  // We need to regenerate the checksums for the image. Checksum format is described here:
  // https://docs.espressif.com/projects/esp-idf/en/latest/api-reference/system/app_image_format.html

  // NOTE this will not work if we enable CONFIG_SECURE_SIGNED_APPS_NO_SECURE_BOOT or CONFIG_SECURE_BOOT_ENABLED

  hash_appended := c[23] == 1

  xor_cs_offset := c.size - 1
  if hash_appended:
    xor_cs_offset = c.size - 1 - 32

  for i := image_data_offset; i < image_data_offset + image_data_size; i++:
    c[xor_cs_offset] ^= c[i]

  if config_data.size > image_config_size:
    throw "data too big to inline into binary"

  c.replace image_data_offset (ByteArray image_data_size)  // Zero out area.
  c.replace image_data_offset config_data
  c.replace image_data_offset+image_config_size unique_id.to_byte_array

  for i := image_data_offset; i < image_data_offset + image_data_size; i++:
    c[xor_cs_offset] ^= c[i]

  if hash_appended:
    boundary := c.size - 32
    c.replace boundary (crypto.sha256 c 0 boundary)

  return c

// Searches for two magic numbers that surround the image data area.
// This is the area in the image that is replaced with the config data.
// The exact location of this area can depend on a future SDK version
// so we don't know it exactly.
get_image_data_position bytes/ByteArray -> List:
  WORD_SIZE ::= 4
  for i := 0; i < bytes.size; i += WORD_SIZE:
    word_1 := LITTLE_ENDIAN.uint32 bytes i
    if word_1 == IMAGE_DATA_MAGIC_1:
      // Search for the end at the (0.5k + word_size) position and at
      // subsequent positions up to a data area of 4k.  We only search at these
      // round numbers in order to reduce the chance of false positives.
      for j := 0x200 + WORD_SIZE; j <= 0x1000 + WORD_SIZE and i + j < bytes.size; j += 0x200:
        word_2 := LITTLE_ENDIAN.uint32 bytes i + j
        if word_2 == IMAGE_DATA_MAGIC_2:
          return [i + WORD_SIZE, j - WORD_SIZE]
  // No magic numbers were found so the image is from a legacy SDK that has the
  // image data at a fixed offset.
  return [LEGACY_IMAGE_DATA_OFFSET, LEGACY_IMAGE_DATA_SIZE]
