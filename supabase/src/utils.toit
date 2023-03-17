// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import reader show Reader SizedReader
import bytes

// TODO(kasper): This is unlikely to be the best place to share this
// code. Should we consider having this as part of the core libraries?
read_all reader/Reader -> ByteArray:
  size/int? := reader is SizedReader
      ? (reader as SizedReader).size
      : null
  first := reader.read
  if not first: return #[]
  second := reader.read
  if not second: return first

  if size:
    result := ByteArray size
    result.replace 0 first
    offset := first.size
    first = null  // Allow garbage collection.
    result.replace offset second
    offset += second.size
    second = null  // Allow garbage collection.
    while chunk := reader.read:
      result.replace offset chunk
      offset += chunk.size
    return offset < size ? result[..offset] : result
  else:
    buffer := bytes.Buffer.with_initial_size first.size + second.size
    buffer.write first
    first = null  // Allow garbage collection.
    buffer.write second
    second = null  // Allow garbage collection.
    while chunk := reader.read: buffer.write chunk
    return buffer.bytes
