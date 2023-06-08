// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be found
// in the LICENSE file.

/**
A semantic version library.
*/

split_semver_ semver/string:
  plus_index := semver.index_of "+"
  if plus_index != -1:
    // Drop the build metadata.
    // We don't need it for comparison.
    semver = semver[..plus_index]

  prerelease/string? := null
  minus_index := semver.index_of "-"
  if minus_index != -1:
    prerelease = semver[minus_index + 1..]
    semver = semver[..minus_index]

  return [semver, prerelease]

/**
Compares a dotted part of a semver string.

This is used for major.minor.patch, but also for prerelease and build.

Generally, the rules are:
- If one is an integer and the other is not, the integer is lower.
- If both are integers compare them.
- If both are strings compare them.
*/
compare_dotted_ a/string b/string -> int:
  a_parts := a.split "."
  b_parts := b.split "."

  max_parts := max a_parts.size b_parts.size
  for i := 0; i < max_parts; i++:
    // If a part is missing it is considered to be equal to 0.
    a_part := i < a_parts.size ? a_parts[i] : "0"
    b_part := i < b_parts.size ? b_parts[i] : "0"

    a_not_int := false
    a_part_int := int.parse a_part --on_error=:
      a_not_int = true
      -1

    b_not_int := false
    b_part_int := int.parse b_part --on_error=:
      b_not_int = true
      -1

    // Semver requires major, minor and patch to be integers.
    // If we get something else we simply compare the two strings without
    // converting to a number.
    if a_not_int and b_not_int:
      comp := a_part.compare_to b_part
      if comp != 0: return comp
    // If one is an integer and the other is not, the integer is lower.
    else if a_not_int:
      return 1
    else if b_not_int:
      return -1
    else:
      // If both are integers we compare them.
      comp := a_part_int.compare_to b_part_int
      if comp != 0: return comp

  return 0

/**
Compares two semver strings.

Returns -1 if a < b, 0 if a == b and 1 if a > b.
*/
// See https://semver.org/#spec-item-11.
compare a/string b/string -> int:
  return compare a b --if_equal=: 0

compare a/string b/string [--if_equal]:
  // Split into version and prerelease.
  a_parts := split_semver_ a
  b_parts := split_semver_ b

  assert: a_parts.size == b_parts.size
  assert: a_parts.size == 2

  a_version := a_parts[0]
  b_version := b_parts[0]

  version_comp := compare_dotted_ a_version b_version
  if version_comp != 0: return version_comp

  a_prerelease := a_parts[1]
  b_prerelease := b_parts[1]

  if not a_prerelease and not b_prerelease:
    return if_equal.call

  // Any prerelease is lower than no prerelease.
  if not a_prerelease: return 1
  if not b_prerelease: return -1

  comp := compare_dotted_ a_prerelease b_prerelease
  if comp != 0: return comp
  return if_equal.call
