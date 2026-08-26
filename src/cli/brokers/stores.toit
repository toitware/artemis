// Copyright (C) 2026 Toitware ApS. All rights reserved.

import uuid show Uuid

/** Stores firmware and application images consumed by devices. */
interface ArtifactStore:
  /** Uploads an application image for the configured scope. */
  upload-image --app-id/Uuid --word-size/int contents/ByteArray -> none

  /** Uploads firmware chunks under $firmware-id. */
  upload-firmware --firmware-id/string chunks/List -> none

  /** Downloads the firmware stored under $id. */
  download-firmware --id/string -> ByteArray

/** Publishes desired update state for devices. */
interface UpdateBroker:
  /** Updates one device's goal using $block. */
  update-goal --device-id/Uuid [block] -> none

  /** Updates several device goals in one operation. */
  update-goals --device-ids/List --goals/List -> none

  /** Registers a newly provisioned device and its initial $state. */
  notify-created --device-id/Uuid --state/Map -> none

/** Reads the broker's goal and reported-state snapshot for known devices. */
interface BrokerStateReader:
  /** Fetches device details keyed by device ID. */
  get-devices --device-ids/List -> Map

/** Reads the optional event history recorded by a broker. */
interface BrokerEventReader:
  /** Fetches events for the selected devices. */
  get-events -> Map
      --types/List?=null
      --device-ids/List
      --limit/int=10
      --since/Time?=null

/** Stores pod metadata, manifests, and content-addressed parts. */
interface PodStore:
  /** Creates or updates a pod description. */
  pod-registry-description-upsert -> int
      --fleet-id/Uuid
      --name/string
      --description/string?

  /** Deletes pod descriptions by ID. */
  pod-registry-descriptions-delete --fleet-id/Uuid --description-ids/List -> none

  /** Adds a pod to a description. */
  pod-registry-add --pod-description-id/int --pod-id/Uuid -> none

  /** Deletes pods by ID. */
  pod-registry-delete --fleet-id/Uuid --pod-ids/List -> none

  /** Sets a tag on a pod. */
  pod-registry-tag-set -> none
      --pod-description-id/int
      --pod-id/Uuid
      --tag/string
      --force/bool=false

  /** Removes a tag from a pod description. */
  pod-registry-tag-remove --pod-description-id/int --tag/string -> none

  /** Lists the pod descriptions in a fleet. */
  pod-registry-descriptions --fleet-id/Uuid -> List

  /** Returns pod descriptions by ID. */
  pod-registry-descriptions --ids/List -> List

  /** Gets pod descriptions by name. */
  pod-registry-descriptions -> List
      --fleet-id/Uuid
      --names/List
      --create-if-absent/bool

  /** Returns the pods belonging to a description. */
  pod-registry-pods --pod-description-id/int -> List

  /** Returns pods by ID. */
  pod-registry-pods --fleet-id/Uuid --pod-ids/List -> List

  /** Resolves pod references to pod IDs. */
  pod-registry-pod-ids --fleet-id/Uuid --references/List -> Map

  /** Uploads a content-addressed pod part. */
  pod-registry-upload-pod-part --part-id/string contents/ByteArray -> none

  /** Downloads a content-addressed pod part. */
  pod-registry-download-pod-part part-id/string -> ByteArray

  /** Uploads a pod manifest. */
  pod-registry-upload-pod-manifest --pod-id/Uuid contents/ByteArray -> none

  /** Downloads a pod manifest. */
  pod-registry-download-pod-manifest --pod-id/Uuid -> ByteArray
