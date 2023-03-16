// Copyright (C) 2022 Toitware ApS. All rights reserved.

import mqtt
import encoding.ubjson
import reader show SizedReader
import uuid

import ..broker
import ...device
import ....shared.mqtt

class ResourceManagerMqtt implements ResourceManager:
  device_/Device
  client_/mqtt.FullClient
  monitors_ ::= {:}

  constructor .device_ .client_:

  /**
  Provides the resource returned by $block to all the tasks
    waiting in a call to $fetch_resource_ for the resource for
    the given $path.
  */
  provide_resource path/string [block] -> bool:
    monitor/ResourceMonitor_? ::= monitors_.get path
    if not monitor: return false
    monitor.provide block.call
    return true

  fetch_image id/uuid.Uuid [block] -> none:
    fetch_resource_ "toit/$device_.organization_id/apps/$id/image$BITS_PER_WORD" block

  fetch_firmware id/string --offset/int=0 [block] -> none:
    assert: offset == 0  // Other case isn't handled yet.
    total_size/int? := null
    parts/List? := null
    fetch_resource_ "toit/$device_.organization_id/firmware/$id": | reader/SizedReader |
      manifest := ubjson.decode (read_all_ reader)
      total_size = manifest["size"]
      parts = manifest["parts"]
    parts.do: | part_offset/int |
      topic := "toit/$device_.organization_id/firmware/$id/$part_offset"
      fetch_resource_ topic: | reader/SizedReader |
        block.call reader part_offset

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
  fetch_resource_ path/string [block] -> none:
    monitor/ResourceMonitor_ ::= monitors_.get path
        --if_absent=: ResourceMonitor_
        --if_present=: throw "Already fetching $path"
    monitors_[path] = monitor
    try:
      client_.subscribe path
      // TODO(kasper): Should $fetch_resource_ take a timeout
      // that doesn't cover the block call? I think so.
      block.call monitor.fetch
    finally:
      catch --trace: client_.unsubscribe path
      monitors_.remove path
      monitor.done

  report_state state/Map -> none:
    client_.publish (topic_state_for device_.id)
        ubjson.encode state
        --qos=1  // TODO(florian): decide whether qos=1 is needed.
        --retain

  report_event --type/string data/any -> none:
    client_.publish (topic_event_for device_.id --type=type)
        ubjson.encode data
        --qos=1  // TODO(florian): decide whether qos=1 is needed.
        --retain


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
