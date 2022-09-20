// Copyright (C) 2022 Toitware ApS. All rights reserved.

import mqtt
import reader show SizedReader

import ..resources

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

  /**
  Fetches the resource for the given $path by requesting it
    and waiting until it is provided through a call from
    another task to $provide_resource.

  The fetched resource is passed onto the $block and the
    resource is released when the block returns.
  */
  fetch_resource path/string [block] -> none:
    monitor/ResourceMonitor_? := null
    try:
      monitor = monitors_.get path
          --init=:
            client_.subscribe path
            ResourceMonitor_
      // TODO(kasper): Should $fetch_resource take a timeout
      // that doesn't cover the block call? I think so.
      block.call monitor.fetch
    finally:
      monitors_.remove path
      catch --trace: client_.unsubscribe path
      if monitor: monitor.done

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
