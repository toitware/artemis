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
          --if_absent=: ResourceMonitor_
          --if_present=: throw "Already fetching $path"
      monitors_[path] = monitor
      client_.subscribe path
      // TODO(kasper): Should $fetch_resource take a timeout
      // that doesn't cover the block call? I think so.
      block.call monitor.fetch
    finally:
      catch --trace: client_.unsubscribe path
      monitors_.remove path
      if monitor: monitor.done

  fetch_resource path/string size/int offsets/List [block] -> none:
    // TODO(kasper): We can make this smarter by pre-subscribing to
    // next part topic when we start reading from the current part.
    // If there is plenty of memory available, we can also accept to
    // get the parts out-of-order and reassemble them.
    offsets.do: | offset/int |
      fetch_resource "$path/$offset": | reader/SizedReader |
        block.call offset reader

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
