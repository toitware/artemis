// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show SizedReader  // For toitdoc.
import encoding.tison
import ..shared.broker_config

decode_broker_config key/string assets/Map -> BrokerConfig?:
  broker_entry := assets.get key --if_present=: tison.decode it
  if not broker_entry: return null
  // We use the key as name for the broker configuration.
  return BrokerConfig.from_json key broker_entry
      --certificate_text_provider=: assets.get it

/**
The resource manager is used to exchange data with the broker.
*/
interface ResourceManager:
  /**
  Downloads the application image with the given $id.

  Calls the $block with the image data and its size.
  */
  fetch_image id/string [block] -> none

  /**
  Downloads the firmware with the given $id.

  The $offset is the offset in the firmware to start downloading from.

  Calls the $block with a $SizedReader and an offset of the given chunk.
  Depending on the implementation, there might be multiple calls to the block.
  */
  fetch_firmware id/string --offset/int=0 [block] -> none

  // TODO(kasper): Poor interface. We shouldn't need to pass
  // the device id here?
  report_status device_id/string status/Map -> none

/**
The event handler, called when the broker has new information.
*/
interface EventHandler:
  /**
  Called when the broker has a new configuration.
  The configuration may not be different.
  */
  handle_update_config new_config/Map resources/ResourceManager

  /**
  // TODO(florian): add documentation.
  */
  handle_nop

/**
An interface to communicate with the CLI through a broker.
*/
interface BrokerService:
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
  connect --device_id/string --callback/EventHandler [block]

  /**
  TODO(florian): add documentation.
  */
  on_idle -> none
