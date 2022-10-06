// Copyright (C) 2020 Toitware ApS. All rights reserved.

import binary show LITTLE_ENDIAN
import bytes
import host.file
import encoding.ubjson as ubjson
import encoding.json as json
import crypto.sha256 show *
import bytes
import host.pipe
import reader show *
import services.arguments show *
import writer
import uuid

import .binary_diff

import ...shared.utils.patch
import ...shared.utils.patch_format

// Chunk the new image into 16k sizes (uncompressed).  These are the points
// where we can resume an incremental update.
SUBCHUNK_SIZE := 16 * 1024

// If a bit of patch is smaller than this, then keep compressing.
MINIMUM_PATCH_CHUNK := 1024

build_trivial_patch new_bytes/ByteArray -> List:
  parts := []
  List.chunk_up 0 new_bytes.size SUBCHUNK_SIZE: | from to |
    writer := bytes.Buffer
    literal_block
        new_bytes[from..to]
        writer
        --with_header=(from == 0)
        --with_footer=(to == new_bytes.size)
    parts.add writer.bytes
  return parts

instantiate --unique_id/uuid.Uuid --use_stdout/bool --raw_config/bool args -> none:
  // TODO(kasper): Renable this somehow.
  return

  /*
  old_sdk_dir := args[0] as string
  old_sdk_model := args[1] as string
  new_sdk_dir := args[2] as string
  new_sdk_model := args[3] as string
  patch_file := args[4] as string
  patch_bytes := file.read_content patch_file
  output_filename := args.size >= 6 ? args[5] : "-"
  if use_stdout:
    output_filename = "-"

  buffer := bytes.Buffer
  while data := pipe.stdin.read:
    buffer.write data

  cfg := buffer.bytes
  if not raw_config:
    m := (json.Decoder).decode cfg
    parsed_config := parse_config m
    cfg = encode_config parsed_config

  new_bytes := inject_config_data new_sdk_dir new_sdk_model cfg unique_id
  old_bytes := file.read_content "$old_sdk_dir/model/$(old_sdk_model)/factory.bin"

  image_data_position := get_image_data_position new_bytes
  image_data_offset := image_data_position[0]
  image_data_size := image_data_position[1]
  image_config_size := image_data_size - uuid.SIZE

  hash_of_new_bytes := sha256 new_bytes

  patch := (ubjson.decode patch_bytes) as List
  if patch is not List or patch.size != 2 or (patch.any: it.any: it is not ByteArray):
    throw "patch file must contain two lists of byte arrays"

  hash_appended := new_bytes[23] == 1
  number_of_checksum_bytes := hash_appended ? 33 : 1
  variable_footer_size := round_up
    number_of_checksum_bytes
    4

  image_data := ByteArray image_data_size
  image_data.replace 0 cfg
  image_data.replace image_config_size unique_id.to_byte_array

  config_writer := WriteableByteArray
  image_data_round_trip_size := literal_block
    image_data
    config_writer
    --with_footer=false
  config_bytes := config_writer.get
  assert: image_data_round_trip_size == config_bytes.size

  end_writer := WriteableByteArray
  end_size := literal_block
    new_bytes.copy
      new_bytes.size - variable_footer_size
      new_bytes.size
    end_writer
    --with_footer=true
  end_bytes := end_writer.get
  assert: end_size == end_bytes.size

  checksum_writer := WriteableByteArray
  new_checksum_block new_bytes checksum_writer hash_of_new_bytes --with_header=false
  new_checksum_bytes := checksum_writer.get

  // The binary diff has a bunch of sections, which can just be concatenated.
  result_writer := WriteableByteArray
  patch[0].do:
    result_writer.write it                // The part of the image before the config.
  result_writer.write config_bytes        // The literal config bytes, not coded as a diff.
  patch[1].do:
    if it != 0:
      result_writer.write it              // The rest of the image.
  result_writer.write new_checksum_bytes  // End with the checksum of the complete new image.
  result_writer.write end_bytes           // The final checksum used by the ESP system to verify.
  result := result_writer.get

  patch_fd := ReadableByteArray result
  rebuilt_fd := WriteableByteArray

  patcher := Patcher
    BufferedReader patch_fd
    old_bytes

  observer := Observer rebuilt_fd

  patch_result := patcher.patch observer

  if not observer.hash_embedded_in_patch:
    throw "No Sha256 hash embedded in patch stream"

  observer.hash_embedded_in_patch.size.repeat:
    if observer.hash_embedded_in_patch[it] != hash_of_new_bytes[it]:
      throw "Sha256 hash embedded in patch stream was corrupted"

  if patch_result == false:
    throw "Old file and patch file did not match"

  rebuilt_bytes := rebuilt_fd.get
  if rebuilt_bytes.size != new_bytes.size: throw "ROUND TRIP FAILED"
  if observer.expected_size != new_bytes.size: throw "ROUND TRIP FAILED"
  new_bytes.size.repeat:
    if rebuilt_bytes[it] != new_bytes[it]: throw "ROUND TRIP FAILED"

  if output_filename == "-":
    stdout := writer.Writer pipe.stdout
    stdout.write result
  else:
    out_writer := writer.Writer
      file.Stream.for_write output_filename
    out_writer.write result
    out_writer.close
*/

class Observer implements PatchObserver:
  rebuilt_fd := ?
  expected_size/int? := null
  hash_embedded_in_patch/ByteArray? := null

  constructor .rebuilt_fd:

  on_write data/ByteArray from/int=0 to/int=data.size -> none:
    rebuilt_fd.write  data from to

  on_size size/int -> none:
    expected_size = size

  on_new_checksum new_hash/ByteArray -> none:
    hash_embedded_in_patch = new_hash

  on_checkpoint patch_postition/int -> none:

class ReadableByteArray implements Reader:
  byte_array_ := null

  constructor .byte_array_:

  read -> ByteArray?:
    result := byte_array_
    byte_array_ = null
    return result

class WriteableByteArray:
  byte_array_/ByteArray := ByteArray 128
  fullness_ := 0

  write input from=0 to=input.size -> int:
    bytes := to - from
    if fullness_ + bytes >= byte_array_.size:
      // Increase size by 1.5 times.
      new_byte_array := ByteArray
        max
          (byte_array_.size * 3) >> 1
          fullness_ + bytes
      new_byte_array.replace 0 byte_array_ 0 byte_array_.size
      byte_array_ = new_byte_array
    byte_array_.replace fullness_ input from to
    fullness_ += bytes
    return bytes

  get -> ByteArray:
    byte_array := byte_array_
    fullness := fullness_
    byte_array_ = ByteArray 128
    fullness_ = 0
    return ByteArray fullness: byte_array[it]
