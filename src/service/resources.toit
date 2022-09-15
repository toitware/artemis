// Copyright (C) 2022 Toitware ApS. All rights reserved.

import mqtt
import reader show SizedReader

interface ResourceFetcher:
  fetch_resource path/string [block] -> none

class ResourceManager implements ResourceFetcher:
  client_/mqtt.FullClient
  monitors_ ::= {:}

  constructor .client_:

  provide_resource path/string [block] -> none:
    monitor/ResourceMonitor_? ::= monitors_.get path
    if monitor: monitor.provide block.call

  // TODO(kasper): Should this take a timeout that doesn't
  // cover the block call? I think so.
  fetch_resource path/string [block] -> none:
    monitor/ResourceMonitor_? := null
    try:
      monitor = monitors_.get path
          --init=:
            client_.subscribe path
            ResourceMonitor_
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
