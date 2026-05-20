// Copyright (C) 2026 Toit contributors.

import uuid show Uuid

/**
A per-service authentication scope.

A $Scope is the additional bit of information a service needs, on top of the
  user's session, to know which slice of resources the operation applies to.
  The user's identity comes from their auth provider session (stored in the
  CLI's config); the scope comes from the fleet file.

For now a $Scope always wraps an organization-id UUID. In the future scopes
  will become opaque, JSON-encodable blobs that each service's auth provider
  interprets independently. Calling code that needs a UUID today should go
  through $as-uuid so the conversion point is greppable when the underlying
  representation broadens.
*/
class Scope:
  organization-id_/Uuid

  constructor.from-organization-id organization-id/Uuid:
    organization-id_ = organization-id

  /**
  Returns the scope as a UUID.

  Today the scope is always a UUID; the throw is here for the future
    when scopes can also be other shapes.
  */
  as-uuid -> Uuid:
    return organization-id_

  operator == other -> bool:
    if other is not Scope: return false
    return organization-id_ == (other as Scope).organization-id_

  hash-code -> int:
    return organization-id_.hash-code

  stringify -> string:
    return "Scope($organization-id_)"
