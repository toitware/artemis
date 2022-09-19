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
    start := null
    monitor/ResourceMonitor_? := null
    try:
      monitor = monitors_.get path
          --init=:
            start = Time.monotonic_us
            client_.subscribe path
            ResourceMonitor_
      // TODO(kasper): Should $fetch_resource take a timeout
      // that doesn't cover the block call? I think so.
      block.call monitor.fetch
      end := Time.monotonic_us
      stamp := monitor.stamp
      if start and stamp: print_ "setting up fetching of $path took $(Duration --us=stamp - start)"
      if start: print_ "fetching $path took $(Duration --us=end - start)"
    finally:
      monitors_.remove path
      catch --trace: client_.unsubscribe path
      if monitor: monitor.done

monitor ResourceMonitor_:
  reader_/SizedReader? := null
  done_/bool := false
  stamp_ := null

  stamp:
    return stamp_

  provide reader/SizedReader -> none:
    stamp_ = Time.monotonic_us
    reader_ = reader
    await: done_
    end := Time.monotonic_us
    print_ "blocked in provide for $(Duration --us=end - stamp_)"

  fetch -> SizedReader:
    await: reader_
    return reader_

  done -> none:
    done_ = true
    reader_ = null
