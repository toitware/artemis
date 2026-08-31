// Copyright (C) 2026 Toit contributors. All rights reserved.

import uuid show Uuid

/**
Stores the declared state of a fleet.

Every store contains the complete declared device inventory. Access wiring,
  broker configuration, and legacy fleet references are not fleet state.
*/
interface FleetStore:
  /** Returns the fleet identity. */
  id -> Uuid

  /** Returns the declared groups and their desired pod references. */
  group-pods -> Map

  /** Returns the complete declared device inventory. */
  devices -> List

  /** Persists changed fleet-level state. */
  save-fleet -> none
      --group-pods/Map?=null

  /** Persists the complete declared device inventory. */
  save-devices devices/List -> none

/** Creates and opens one configured fleet-store implementation. */
interface FleetStoreStrategy:
  /** Opens the configured fleet store. */
  open -> FleetStore

  /** Creates and opens the configured fleet store. */
  create -> FleetStore
      --id/Uuid
      --group-pods/Map
      --devices/List

/**
Provides temporary access to broker wiring stored in legacy fleet files.

This interface keeps compatibility data out of $FleetStore while workspaces
  replace the old combined fleet-file format.
*/
interface LegacyFleetWiring:
  /** Returns the referenced fleet identity. */
  id -> Uuid

  /** Returns the selected broker name. */
  broker-name -> string

  /** Returns the brokers from which the fleet is migrating. */
  migrating-from -> List

  /** Returns legacy server configurations by name. */
  servers -> Map

  /** Returns recovery URLs retained by the legacy fleet-file format. */
  recovery-urls -> List

  /** Persists changed legacy broker wiring. */
  save-wiring -> none
      --broker-name/string?=null
      --migrating-from/List?=null
      --servers/Map?=null
      --recovery-urls/List?=null

  /** Writes a legacy access-only reference file. */
  write-reference --path/string -> none
