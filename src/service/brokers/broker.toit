// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import log
import net
import reader show Reader  // For toitdoc.
import uuid

import .http show BrokerServiceHttp

import ..device
import ...shared.server-config

/**
The resource manager is used to exchange data with the broker.

TODO(kasper): Rename to BrokerConnection.
*/
interface BrokerConnection:
  /**
  Fetches the goal from the broker.

  If $wait is true, waits until the goal may have changed and
    returns the new goal.

  If $wait is false, returns the goal if it is known to have
    changed. Otherwise, returns null.
  */
  fetch-goal-state --wait/bool -> Map?

  /**
  Downloads the application image with the given $id.

  Calls the $block with a $Reader.
  */
  fetch-image id/uuid.Uuid [block] -> none

  /**
  Downloads the firmware with the given $id.

  The $offset is the offset in the firmware to start downloading from.

  Calls the $block with a $Reader and an offset of the given chunk. The block
    must return the next offset it wants to download from.
  Some implementations don't respect the returned value yet, and users of
    this class must be able to deal with continuous chunks.

  Depending on the implementation, there might be multiple calls to the block.
  */
  fetch-firmware id/string --offset/int=0 [block] -> none

  /**
  Reports the state of the connected device.
  */
  report-state state/Map -> none

  /**
  Reports an event to the broker.

  The $data must be a JSON-serializable object.
  The $type is a string that describes the type of event.
  */
  report-event --type/string data/any -> none

  /**
  Closes the connection to the broker.
  */
  close -> none

/**
An interface to communicate with the CLI through a broker.
*/
interface BrokerService:
  constructor logger/log.Logger server-config/ServerConfig:
    if server-config is ServerConfigSupabase:
      supabase-config := server-config as ServerConfigSupabase
      host := supabase-config.host
      port := null
      colon-pos := host.index-of ":"
      if colon-pos >= 0:
        port = int.parse host[colon-pos + 1..]
        host = host[..colon-pos]
      der := supabase-config.root-certificate-der
      http-config := ServerConfigHttp
          server-config.name
          --host=host
          --port=port
          --path="/functions/v1/b"  // TODO(florian): get the path from the config.
          --poll-interval=supabase-config.poll-interval
          --root-certificate-names=null
          --root-certificate-ders=der ? [der] : null
          --admin-headers=null
          --device-headers=null
      return BrokerServiceHttp logger http-config
    else if server-config is ServerConfigHttp:
      return BrokerServiceHttp logger (server-config as ServerConfigHttp)
    else:
      throw "unknown broker $server-config"

  /**
  Connects to the broker.

  Returns a $BrokerConnection, which can be used to interact with
    the broker and exchange data with it.

  The returned $BrokerConnection should be closed through a call
    to $BrokerConnection.close when it is no longer needed.
  */
  connect --network/net.Client --device/Device -> BrokerConnection
