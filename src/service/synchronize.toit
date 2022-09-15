// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import log
import net
import monitor
import mqtt
import mqtt.packets as mqtt
import uuid
import reader show SizedReader

import system.containers

import .actions
import .applications
import .jobs
import .resources

import ..shared.connect
import ..shared.json_diff show Modification

CLIENT_ID ::= "toit/artemis-service-$(random 0x3fff_ffff)"

revision/int? := null
config/Map := {:}
max_offline/Duration? := null

// Index in return value from `process_stats`.
BYTES_ALLOCATED ::= 4

class SynchronizeJob extends Job:
  logger_/log.Logger
  device/ArtemisDevice
  applications_/ApplicationManager
  actions_/ActionManager ::= ActionManager

  constructor logger/log.Logger .device .applications_:
    logger_ = logger.with_name "synchronize"
    super "synchronize"

  schedule now/JobTime -> JobTime?:
    if not last_run or not max_offline: return now
    return last_run + max_offline

  run -> none:
    stats := List BYTES_ALLOCATED + 1  // Use this to collect stats to avoid allocation.
    allocated := (process_stats stats)[BYTES_ALLOCATED]
    logger_.info "connecting to broker" --tags={"device": device.name}

    run_client_: | resources/ResourceManager |
      while true:
        bundle/ActionBundle? := actions_.next
        if bundle: config = actions_.commit bundle
        if actions_.has_next: continue

        // We only handle incomplete applications when we're done processing
        // the other actions. This means that we prioritize firmware updates
        // and configuration changes over fetching applications.
        if applications_.any_incomplete:
          bundle = ActionBundle config  // Doesn't change the configuration.
          bundle.add (ActionApplicationFetch applications_ actions_ resources)
          actions_.add bundle
          continue

        new_allocated := (process_stats stats)[BYTES_ALLOCATED]
        delta := new_allocated - allocated
        logger_.info "synchronized" --tags={"allocated": delta}
        allocated = new_allocated
        if max_offline:
          logger_.info "going offline" --tags={"duration": max_offline}
          return

  handle_nop_ -> none:
    actions_.add null

  handle_new_config_ new_config/Map -> none:
    modification/Modification? := Modification.compute
        --from=config
        --to=new_config
    if not modification: return

    bundle := ActionBundle new_config
    modification.on_map "apps"
        --added=: | key value |
          // An app just appeared in the configuration. If we got an id
          // for it, we install it.
          id ::= value is Map ? value.get Application.CONFIG_ID : null
          if id: bundle.add (ActionApplicationInstall applications_ key id)
        --removed=: | key value |
          // An app disappeared completely from the configuration. We
          // uninstall it, if we got an id for it.
          id := value is string ? value : null
          id = id or value is Map ? value.get Application.CONFIG_ID : null
          if id: bundle.add (ActionApplicationUninstall applications_ key id)
        --modified=: | key nested/Modification |
          value ::= new_config["apps"][key]
          id ::= value is Map ? value.get Application.CONFIG_ID : null
          handle_app_modification_ bundle key id nested

    modification.on_value "max-offline"
        --added=: | value |
          max_offline = (value is int) ? Duration --s=value : null
        --removed=: | value |
          max_offline = null

    actions_.add bundle

  handle_app_modification_ bundle/ActionBundle name/string id/string? modification/Modification -> none:
    modification.on_value "id"
        --added=: | value |
          // An application that existed in the configuration suddenly
          // got an id. Great. Let's install it!
          bundle.add (ActionApplicationInstall applications_ name value)
          return
        --removed=: | value |
          // Woops. We just lost the id for an application we already
          // had in the configuration. We need to uninstall.
          bundle.add (ActionApplicationUninstall applications_ name value)
          return
        --updated=: | from to |
          // An application had its id (the code) updated. We uninstall
          // the old version and install the new one.
          bundle.add (ActionApplicationUninstall applications_ name from)
          bundle.add (ActionApplicationInstall applications_ name to)
          return
    // The configuration for the application was updated, but we didn't
    // change its id, so the code for it is still valid. We add a pending
    // action to make sure we let the application of the change possibly
    // by restarting it.
    if id: bundle.add (ActionApplicationUpdate applications_ name id)

  run_client_ [block]:
    network ::= net.open
    transport ::= create_transport network
    client/mqtt.FullClient? := mqtt.FullClient --transport=transport

    // Since we are using `retain` for important data, we simply connect
    // with the clean-session flag. The broker does not need to save
    // QoS packets that aren't retained.
    last_will ::= mqtt.LastWill device.topic_presence "disappeared".to_byte_array
        --retain
        --qos=0
    options ::= mqtt.SessionOptions
        --client_id=CLIENT_ID
        --clean_session
        --last_will=last_will

    client.connect --options=options
    disconnected := monitor.Latch
    resources ::= ResourceManager client

    handle_task/Task? := ?
    handle_task = task::
      catch --trace:
        try:
          subscribed_to_config := false
          new_config/Map? := null
          client.handle: | packet/mqtt.Packet |
            if packet is mqtt.PublishPacket:
              publish := packet as mqtt.PublishPacket
              topic := publish.topic
              if topic == device.topic_revision:
                new_revision := ubjson.decode publish.payload
                if new_revision != revision:
                  revision = new_revision
                  if not subscribed_to_config:
                    subscribed_to_config = true
                    client.subscribe device.topic_config
                  if new_config and revision == new_config["revision"]:
                    handle_new_config_ new_config
                else:
                  handle_nop_
              else if topic == device.topic_config:
                new_config = ubjson.decode publish.payload
                if revision == new_config["revision"]:
                  handle_new_config_ new_config
              else:
                known := resources.provide_resource topic: publish.payload_stream
                if not known: logger_.warn "unhandled publish packet" --tags={"topic": topic}
        finally:
          critical_do:
            disconnected.set true
            client.close --force
            network.close
          client = null
          handle_task = null

    try:
      // Wait for the client to run.
      client.when_running: null
      client.publish device.topic_presence "online".to_byte_array --retain
      client.subscribe device.topic_revision
      block.call resources
    finally:
      try:
        if client: client.publish device.topic_presence "offline".to_byte_array --retain
        if client: client.close
        with_timeout --ms=3_000: disconnected.get
      finally:
        if handle_task: handle_task.cancel
