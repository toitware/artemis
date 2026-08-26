// Copyright (C) 2026 Toitware ApS. All rights reserved.

import semver show SemanticVersion

ARTEMIS-V1-MAJOR ::= 1

/**
Parses the given Artemis $version.

Returns null if $version is absent or is not a semantic version.
*/
parse-artemis-version version/string? -> SemanticVersion?:
  if not version: return null
  return SemanticVersion.parse version --accept-v --if-error=(: null)

/**
Returns whether the given Artemis $version uses the V1 API.
*/
is-artemis-v1-version version/string? -> bool:
  semantic-version := parse-artemis-version version
  if not semantic-version: return false
  return semantic-version.major == ARTEMIS-V1-MAJOR
