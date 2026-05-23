// Copyright (C) 2026 Toit contributors.

/**
A per-service authentication scope.

A $Scope is the additional bit of information a service needs, on top of the
  user's session, to know which slice of resources the operation applies to.
  The user's identity comes from their auth provider session (stored in the
  CLI's config); the scope comes from the fleet file.

A scope wraps a JSON-encodable value (string, Map, List, etc.). Each
  service's auth provider issues scopes in whatever shape makes sense for
  its backend; the consuming backend knows that shape and interprets the
  $to-json value accordingly. Scopes are opaque to anyone else in the
  pipeline.

For the current Toit-hosted setup, scopes wrap an organization-id UUID as
  a string. A hypothetical GitHub-backed pod-store might wrap
  `{"owner": "toit", "repo": "fleet-pods"}` instead.
*/
class Scope:
  json_/any

  /**
  Constructs a scope from any JSON-encodable value.

  The $value is taken as-is; no validation. It is the caller's
    responsibility to ensure the value is encodable by the JSON encoder.
  */
  constructor value/any:
    json_ = value

  /**
  Returns the scope's JSON-encodable value.
  */
  to-json -> any:
    return json_

  stringify -> string:
    return "Scope($json_)"
