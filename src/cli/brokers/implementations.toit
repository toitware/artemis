// Copyright (C) 2026 Toitware ApS. All rights reserved.

import .server
import .stores
import .http.base
import .supabase

/** Constructs the artifact store configured to use $server. */
create-artifact-store server/Server -> ArtifactStore:
  if server is ServerSupabase:
    return ArtifactStoreSupabase (server as ServerSupabase)
  return ArtifactStoreHttp server

/**
Constructs the update broker configured to use $server.

If $combined is true, the same server also provides the Artemis device
  registry and provisioning updates both services.
*/
create-update-broker server/Server --combined/bool -> UpdateBroker:
  if server is ServerSupabase:
    if combined:
      return UpdateBrokerSupabaseCombined (server as ServerSupabase)
    return UpdateBrokerSupabase (server as ServerSupabase)
  if combined:
    return UpdateBrokerHttpCombined server
  return UpdateBrokerHttp server

/** Constructs the optional broker-state reader configured to use $server. */
create-broker-state-reader server/Server -> BrokerStateReader:
  if server is ServerSupabase:
    return BrokerStateReaderSupabase (server as ServerSupabase)
  return BrokerStateReaderHttp server

/** Constructs the optional broker-event reader configured to use $server. */
create-broker-event-reader server/Server -> BrokerEventReader:
  if server is ServerSupabase:
    return BrokerEventReaderSupabase (server as ServerSupabase)
  return BrokerEventReaderHttp server

/** Constructs the pod store configured to use $server. */
create-pod-store server/Server -> PodStore:
  if server is ServerSupabase:
    return PodStoreSupabase (server as ServerSupabase)
  return PodStoreHttp server
