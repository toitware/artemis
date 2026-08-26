// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show Cli

import ..auth
import ...shared.server-config
import .stores
import .supabase
import .http.base

/**
Adapter for backends that provide all Artemis interfaces through one service.

The current HTTP and Supabase configurations are combined backends. Keeping
  that deployment shape behind this adapter lets callers depend on the
  narrower $UpdateBroker, $ArtifactStore, $FleetStore, and $PodStore
  interfaces. Future configurations can construct those interfaces
  independently.
*/
interface CombinedBackend implements Authenticatable:
  constructor server-config/ServerConfig --cli/Cli:
    if server-config is ServerConfigSupabase:
      return create-combined-backend-supabase-http
          (server-config as ServerConfigSupabase)
          --cli=cli
    if server-config is ServerConfigHttp:
      http-config := server-config as ServerConfigHttp
      if http-config.tenancy == TENANCY-SHARED:
        return create-combined-backend-http-toit-shared http-config
      return create-combined-backend-http-toit http-config
    throw "Unknown backend config type"

  /** Closes this backend. */
  close -> none

  /** Whether this backend is closed. */
  is-closed -> bool

  /** A unique ID that can be used for caching. */
  id -> string

  /** The artifact-storage interface implemented by this backend. */
  artifact-store -> ArtifactStore

  /** The update-broker interface implemented by this backend. */
  update-broker -> UpdateBroker

  /** The fleet-storage interface implemented by this backend. */
  fleet-store -> FleetStore

  /** The pod-storage interface implemented by this backend. */
  pod-store -> PodStore

  /** See $Authenticatable.ensure-authenticated. */
  ensure-authenticated [block]

  /** See $Authenticatable.sign-up. */
  sign-up --email/string --password/string

  /** See $(Authenticatable.sign-in --email --password). */
  sign-in --email/string --password/string

  /** See $(Authenticatable.sign-in --provider --cli --open-browser). */
  sign-in --provider/string --cli/Cli --open-browser

  /** See $Authenticatable.update. */
  update --email/string? --password/string?

  /** See $Authenticatable.logout. */
  logout

with-combined-backend server-config/ServerConfig --cli/Cli [block]:
  backend := CombinedBackend server-config --cli=cli
  try:
    block.call backend
  finally:
    backend.close
