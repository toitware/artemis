// Copyright (C) 2022 Toitware ApS. All rights reserved.

import mqtt
import encoding.ubjson
import reader show SizedReader

import ..mediator_service

class ResourceManagerMqtt implements ResourceManager:
  client_/mqtt.FullClient
  monitors_ ::= {:}

  constructor .client_:

  /**
  Provides the resource returned by $block to all the tasks
    waiting in a call to $fetch_resource for the resource for
    the given $path.
  */
  provide_resource path/string [block] -> bool:
    monitor/ResourceMonitor_? ::= monitors_.get path
    if not monitor: return false
    monitor.provide block.call
    return true

  fetch_image id/string [block] -> none:
    fetch_resource "toit/apps/$id/image$BITS_PER_WORD" block

  fetch_firmware id/string --offset/int=0 [block] -> none:
    assert: offset == 0  // Other case isn't handled yet.
    total_size/int? := null
    parts/List? := null
    fetch_resource "toit/firmware/$id": | reader/SizedReader |
      manifest := ubjson.decode (read_all_ reader)
      total_size = manifest["size"]
      parts = manifest["parts"]
    parts.do: | offset/int |
      topic := "toit/firmware/$id/$offset"
      fetch_resource topic: | reader/SizedReader |
        block.call reader offset

  // TODO(kasper): Get rid of this again. Can we get a streaming
  // ubjson reader?
  static read_all_ reader/SizedReader -> ByteArray:
    bytes := ByteArray reader.size
    offset := 0
    while data := reader.read:
      bytes.replace offset data
      offset += data.size
    return bytes

  /**
  Fetches the resource for the given $path by requesting it
    and waiting until it is provided through a call from
    another task to $provide_resource.

  The fetched resource is passed onto the $block and the
    resource is released when the block returns.
  */
  fetch_resource path/string [block] -> none:
    monitor/ResourceMonitor_ ::= monitors_.get path
        --if_absent=: ResourceMonitor_
        --if_present=: throw "Already fetching $path"
    monitors_[path] = monitor
    try:
      client_.subscribe path
      // TODO(kasper): Should $fetch_resource take a timeout
      // that doesn't cover the block call? I think so.
      block.call monitor.fetch
    finally:
      catch --trace: client_.unsubscribe path
      monitors_.remove path
      monitor.done

  report_status device_id/string status/Map -> none:
    // TODO(kasper): Not implemented yet.
    unreachable

monitor ResourceMonitor_:
  reader_/SizedReader? := null
  done_/bool := false

  provide reader/SizedReader -> none:
    reader_ = reader
    await: done_

  fetch -> SizedReader:
    await: reader_
    return reader_

  done -> none:
    done_ = true
    reader_ = null
