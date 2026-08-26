// Copyright (C) 2026 Toitware ApS. All rights reserved.

import semver

ARTEMIS-V1-MAJOR ::= 1

/**
Returns the major component of the given Artemis $version.

Returns null if $version is absent or is not a semantic version.
*/
artemis-version-major version/string? -> int?:
  if not version or not semver.is-valid version: return null
  normalized := version
  if normalized.starts-with "v" or normalized.starts-with "V":
    normalized = normalized[1..]
  parts := normalized.split "."
  return int.parse parts.first

/**
Returns whether the given Artemis $version uses the V1 API.
*/
is-artemis-v1-version version/string? -> bool:
  return (artemis-version-major version) == ARTEMIS-V1-MAJOR

/**
Returns whether a CLI with $cli-major can generate firmware for $target-version.

Pre-V1 CLIs remain permissive so the V1 checks can land before the first V1
  release. Starting with V1, CLI and service API generations must match.
*/
is-supported-artemis-target cli-major/int target-version/string? -> bool:
  if cli-major < ARTEMIS-V1-MAJOR: return true
  return (artemis-version-major target-version) == cli-major
