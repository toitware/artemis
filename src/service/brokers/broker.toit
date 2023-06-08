// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import log
import net
import reader show Reader  // For toitdoc.
import uuid

import .http show BrokerServiceHttp

import ..device
import ...shared.server_config

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
  fetch_goal_state --wait/bool -> Map?

  /**
  Downloads the application image with the given $id.

  Calls the $block with a $Reader.
  */
  fetch_image id/uuid.Uuid [block] -> none

  /**
  Downloads the firmware with the given $id.

  The $offset is the offset in the firmware to start downloading from.

  Calls the $block with a $Reader and an offset of the given chunk. The block
    must return the next offset it wants to download from.
  Some implementations don't respect the returned value yet, and users of
    this class must be able to deal with continuous chunks.

  Depending on the implementation, there might be multiple calls to the block.
  */
  fetch_firmware id/string --offset/int=0 [block] -> none

  /**
  Reports the state of the connected device.
  */
  report_state state/Map -> none

  /**
  Reports an event to the broker.

  The $data must be a JSON-serializable object.
  The $type is a string that describes the type of event.
  */
  report_event --type/string data/any -> none

  /**
  Closes the connection to the broker.
  */
  close -> none

/**
An interface to communicate with the CLI through a broker.
*/
interface BrokerService:
  constructor logger/log.Logger server_config/ServerConfig:
    if server_config is ServerConfigSupabase:
      supabase_config := server_config as ServerConfigSupabase
      host := supabase_config.host
      port := null
      colon_pos := host.index_of ":"
      if colon_pos >= 0:
        port = int.parse host[colon_pos + 1..]
        host = host[..colon_pos]
      // TODO(florian): get the path from the config.
      der := supabase_config.root_certificate_der
      http_config := ServerConfigHttp
          server_config.name
          --host=host
          --port=port
          --path="/functions/v1/b"
          --poll_interval=supabase_config.poll_interval
          --root_certificate_names=null
          --root_certificate_ders=der ? [der] : null
          --admin_headers=null
          --device_headers=null
      return BrokerServiceHttp logger http_config
    else if server_config is ServerConfigHttp:
      return BrokerServiceHttp logger (server_config as ServerConfigHttp)
    else:
      throw "unknown broker $server_config"

  /**
  Connects to the broker.

  Returns a $BrokerConnection, which can be used to interact with
    the broker and exchange data with it.

  The returned $BrokerConnection should be closed through a call
    to $BrokerConnection.close when it is no longer needed.
  */
  connect --network/net.Client --device/Device -> BrokerConnection
