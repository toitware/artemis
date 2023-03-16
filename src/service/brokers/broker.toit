// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import log
import reader show SizedReader  // For toitdoc.
import uuid

import .supabase.synchronize show BrokerServiceSupabase
import .mqtt.synchronize show BrokerServiceMqtt
import .http.synchronize show BrokerServiceHttp

import ..device
import ...shared.server_config

/**
The resource manager is used to exchange data with the broker.
*/
interface ResourceManager:
  /**
  Downloads the application image with the given $id.

  Calls the $block with a $SizedReader.
  */
  fetch_image id/uuid.Uuid [block] -> none

  /**
  Downloads the firmware with the given $id.

  The $offset is the offset in the firmware to start downloading from.

  Calls the $block with a $SizedReader and an offset of the given chunk. The block
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
The event handler, called when the broker has new information.
*/
interface EventHandler:
  /**
  Called when the broker has a goal state.
  The goal state may not be different.
  If the $goal is null, no goal exists and the device should use the
    firmware state.
  */
  handle_goal goal/Map? resources/ResourceManager

  /**
  // TODO(florian): add documentation.
  */
  handle_nop

/**
An interface to communicate with the CLI through a broker.
*/
interface BrokerService:
  constructor logger/log.Logger server_config/ServerConfig:
    if server_config is ServerConfigSupabase:
      return BrokerServiceSupabase logger (server_config as ServerConfigSupabase)
    else if server_config is ServerConfigMqtt:
      return BrokerServiceMqtt logger --server_config=(server_config as ServerConfigMqtt)
    else if server_config is ServerConfigHttpToit:
      http_server_config := server_config as ServerConfigHttpToit
      return BrokerServiceHttp logger http_server_config.host http_server_config.port
    else:
      throw "unknown broker $server_config"


  /**
  Connects to the broker.

  Starts listening for events, and notifies the $callback when it receives one. This
    can be implemented through polling, MQTT subscriptions, long-polling, ...

  Calls the $block with a $ResourceManager as argument.
  Once the $block returns, the connection is closed.

  The connect call is responsible for ensuring that the service and the broker
    are in a consistent state. For some platforms, the broker may automatically
    inform the service (for example, through MQTT subscriptions). For others,
    the service may need to poll the broker for changes.

  It is safe to call the callback too often, as long as the arguments are correct.
  */
  connect --device/Device --callback/EventHandler [block]

  /**
  TODO(florian): add documentation.
  */
  on_idle -> none
