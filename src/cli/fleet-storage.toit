// Copyright (C) 2026 Toit contributors.

import uuid show Uuid

/**
A storage backend for fleet data.

Holds the fleet's configuration, the device list, pod specifications and
  identity files. Today the only implementation is filesystem-backed
  (`FilesystemFleetStorage` in src/cli/fleet-storage-fs.toit). Future
  implementations could store fleet data in the cloud or in a Git
  repository accessed through a content API.

The store is constructed for one fleet root (or one fleet reference). It
  is the source of truth for the fleet's persistent state; the `Fleet`
  and `FleetWithDevices` classes coordinate domain logic on top of it.
*/
interface FleetStorage:
  /**
  A user-facing display of the storage root.

  Used in messages like "Fleet stored at $display-root". Returns null if
    there is no meaningful root to show (for example, an in-memory test
    storage).
  */
  display-root -> string?

  /**
  Whether this storage supports device management.

  Reference fleets only support pod operations and report false here.
  */
  supports-devices -> bool

  /** Whether the fleet config (commonly fleet.json) exists in storage. */
  has-fleet-config -> bool

  /**
  Reads the fleet config as a Map.

  Aborts via the CLI UI if the config cannot be read or is not a Map.
  */
  read-fleet-config -> Map

  /** Writes the given $config as the fleet config. */
  write-fleet-config config/Map -> none

  /** Whether the devices file (commonly devices.json) exists in storage. */
  has-devices -> bool

  /**
  Reads the devices file as a Map.

  Aborts via the CLI UI if the file cannot be read or is not a Map.
  */
  read-devices -> Map

  /** Writes the given $devices as the devices file. */
  write-devices devices/Map -> none

  /** Whether a pod spec with the given $name already exists. */
  has-pod-spec name/string -> bool

  /**
  Writes a pod spec with the given $name and $contents.

  $contents is the raw on-disk representation, typically a yaml document.
  */
  write-pod-spec name/string contents/ByteArray -> none

  /**
  Writes an identity file for $device-id.

  $output-directory is a user request: filesystem storages honor it,
    while cloud storages may ignore it and write to a local temp
    directory. Returns the on-disk path to the identity file, suitable
    for flashing tools like jag.
  */
  write-identity --device-id/Uuid contents/ByteArray --output-directory/string -> string
