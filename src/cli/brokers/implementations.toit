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

/** Constructs the broker backend configured to use $server. */
create-broker-backend server/Server -> BrokerBackend:
  if server is ServerSupabase:
    return BrokerBackendSupabase (server as ServerSupabase)
  return BrokerBackendHttp server

/** Constructs the pod store configured to use $server. */
create-pod-store server/Server -> PodStore:
  if server is ServerSupabase:
    return PodStoreSupabase (server as ServerSupabase)
  return PodStoreHttp server
