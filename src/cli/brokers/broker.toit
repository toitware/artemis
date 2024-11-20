// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show Cli
import host.file
import encoding.json
import net
import uuid show Uuid

import ..auth
import ..config
import ..event
import ..device
import ..pod-registry
import ...shared.server-config
import .supabase
import .http.base

/**
Responsible for allowing the Artemis CLI to talk to Artemis services on devices.
*/
interface BrokerCli implements Authenticatable:
  // TODO(florian): we probably want to add a `connect` function to this interface.
  // At the moment we require the connection to be open when artemis receives the
  // broker.

  constructor server-config/ServerConfig --cli/Cli:
    if server-config is ServerConfigSupabase:
      return create-broker-cli-supabase-http (server-config as ServerConfigSupabase) --cli=cli
    if server-config is ServerConfigHttp:
      return create-broker-cli-http-toit (server-config as ServerConfigHttp)
    throw "Unknown broker config type"

  /** Closes this broker. */
  close -> none

  /** Whether this broker is closed. */
  is-closed -> bool

  /**
  A unique ID of the broker that can be used for caching.
  May contain "/", in which case the cache will use subdirectories.
  */
  id -> string

  /**
  Ensures that the user is authenticated.

  If the user is not authenticated, the $block is called.
  */
  ensure-authenticated [block]

  /**
  Signs the user up with the given $email and $password.
  */
  sign-up --email/string --password/string

  /**
  Signs the user in with the given $email and $password.
  */
  sign-in --email/string --password/string

  /**
  Signs the user in using OAuth.
  */
  sign-in --provider/string --cli/Cli --open-browser

  /**
  Updates the user's email and/or password.
  */
  update --email/string? --password/string?

  /**
  Signs the user out.
  */
  logout

  /**
  Updates the goal state of the device with the given $device-id.

  The block is called with a $DeviceDetailed as argument:

  The $block must return a new goal state which replaces the actual goal state.

  The $block is allowed to modify the state maps of the $DeviceDetailed, but is
    still required to return the new goal state. It is not enough to just
    modify the goal map of the $DeviceDetailed.
  */
  update-goal --device-id/Uuid [block] -> none

  /**
  Updates the goal states of the devices with the given $device-ids.

  The two lists $device-ids and $goals must be of the same length.
  The $device-ids list must be a list of UUIDs.
  The $goals list must be a list of Maps, where each map is a goal state.
  */
  update-goals --device-ids/List --goals/List -> none

  /**
  Uploads an application image with the given $app-id so that a device in
    $organization-id can fetch it.

  There may be multiple images for the same $app-id, that differ in the $word-size.
    Generally $word-size is either 32 or 64.
  */
  upload-image
      --organization-id/Uuid
      --app-id/Uuid
      --word-size/int
      contents/ByteArray -> none

  /**
  Uploads a firmware with the given $firmware-id so that a device in
    $organization-id can fetch it.

  The $chunks are a list of byte arrays.
  */
  upload-firmware --organization-id/Uuid --firmware-id/string chunks/List -> none

  /**
  Downloads a firmware chunk inside the given $organization-id.
  */
  download-firmware --organization-id/Uuid --id/string -> ByteArray

  /**
  Informs the broker that a device with the given $device-id has been provisioned.
  The $state map is the initial state of the device. Until it connects to the
    broker there is (probably) only identity information in it.
  */
  notify-created --device-id/Uuid --state/Map -> none

  /**
  Fetches all events of the given $types for all devices in the $device-ids list.
  If no $types are given, all events are returned.
  Returns a mapping from device-id to list of $Event s.
  At most $limit events per device are returned.
  If $since is not null, only events that are newer than $since are returned.
  If there are no events for a device, the device is not included in the map.
  */
  get-events -> Map
      --types/List?=null
      --device-ids/List
      --limit/int=10
      --since/Time?=null

  /**
  Fetches the device details for the given device ids.
  Returns a map from id to $DeviceDetailed.
  */
  get-devices --device-ids/List -> Map

  /**
  Creates a new pod description.
  */
  pod-registry-description-upsert -> int
      --fleet-id/Uuid
      --organization-id/Uuid
      --name/string
      --description/string?

  /**
  Deletes the pod descriptions with the given ids.
  */
  pod-registry-descriptions-delete --fleet-id/Uuid --description-ids/List -> none

  /**
  Adds a pod.
  */
  pod-registry-add -> none
      --pod-description-id/int
      --pod-id/Uuid

  /**
  Deletes the pods with the given ids.
  */
  pod-registry-delete --fleet-id/Uuid --pod-ids/List -> none

  /**
  Adds a tag.
  */
  pod-registry-tag-set -> none
      --pod-description-id/int
      --pod-id/Uuid
      --tag/string
      --force/bool=false

  /**
  Removes a tag.

  Does nothing if the tag is not set.
  */
  pod-registry-tag-remove -> none
      --pod-description-id/int
      --tag/string

  /**
  Lists pod descriptions.

  Returns a list of $PodRegistryDescription.
  */
  pod-registry-descriptions --fleet-id/Uuid -> List

  /**
  Returns a list of descriptions by their ids.

  Returns a list of $PodRegistryDescription.
  */
  pod-registry-descriptions --ids/List -> List

  /**
  Gets pod descriptions by name.

  If $create-if-absent is true, a new description is created if none
    with the given name exists.

  Returns a list of $PodRegistryDescription.
  */
  pod-registry-descriptions -> List
      --fleet-id/Uuid
      --organization-id/Uuid
      --names/List
      --create-if-absent/bool

  /**
  Returns the pods of a pod description.

  Returns a list of $PodRegistryEntry.
  */
  pod-registry-pods --pod-description-id/int -> List

  /**
  Returns the pods with the given $pod-ids.

  Returns a list of $PodRegistryEntry.
  */
  pod-registry-pods --fleet-id/Uuid --pod-ids/List -> List

  /**
  Returns the pod-id for the given name/tag combinations.

  Returns a map from $PodReference to pod ID. References that were not
    found are not included in the map.

  The $references list must contain $PodReference objects.
  */
  pod-registry-pod-ids --fleet-id/Uuid --references/List -> Map

  /**
  Uploads a pod part to the registry.
  */
  pod-registry-upload-pod-part -> none
      --organization-id/Uuid
      --part-id/string
      contents/ByteArray

  /**
  Downloads a pod part from the registry.
  */
  pod-registry-download-pod-part part-id/string --organization-id/Uuid -> ByteArray

  /**
  Saves the manifest of a pod.

  The $contents is a binary blob (for example a UBJSON map) that can be used to recover
    a pod from its parts.
  */
  pod-registry-upload-pod-manifest -> none
      --organization-id/Uuid
      --pod-id/Uuid
      contents/ByteArray

  /**
  Downloads the manifest of a pod.
  */
  pod-registry-download-pod-manifest -> ByteArray
      --organization-id/Uuid
      --pod-id/Uuid

with-broker server-config/ServerConfig --cli/Cli [block]:
  broker := BrokerCli server-config --cli=cli
  try:
    block.call broker
  finally:
    broker.close
