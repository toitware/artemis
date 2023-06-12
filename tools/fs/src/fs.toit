// Copyright (C) 2023 Toitware ApS. All rights reserved.

// TODO(florian): make this library available in the host package?

/**
Whether the given $path is absolute.

On Windows the term "fully qualified" is often used for absolute paths.
*/
is_absolute path/string --path_platform/string=platform -> bool:
  if path_platform == PLATFORM_WINDOWS:
    if path.starts_with "\\\\" or path.starts_with "//": return true
    return path.size > 2
        and path[1] == ':'
        and (path[2] == '/' or path[2] == '\\')
  else:
    return path.starts_with "/"

/**
Whether the given $path is rooted.

On Posix systems (Linux, Mac, etc.) a rooted path is a path that starts with
  a slash, and is thus equivalent to $is_absolute.

On Windows, a rooted path is a path that is fixed to a specific drive or UNC path.

# Examples
On Windows:
```
  is_rooted "C:\\foo\\bar"     // True.
  is_rooted "C:/foo/bar"       // True.
  is_rooted "C:foo\\bar"       // True.
  is_rooted "\\foo\\bar"       // True.
  is_rooted "/foo/bar"         // True.
  is_rooted "//share/foo/bar"  // True.
  is_rooted "foo/bar"          // False.
  is_rooted "../foo/bar"       // False.
```
*/
is_rooted path/string --path_platform/string=platform -> bool:
  if is_absolute path: return true
  if path_platform != PLATFORM_WINDOWS: return false
  if path.starts_with "\\" or path.starts_with "/": return true
  return path.size > 2 and path[1] == ':'

/**
Whether the given $path is relative.

A path is relative if it is not rooted.
*/
is_relative path/string --path_platform/string=platform -> bool:
  return not is_rooted path --path_platform=path_platform

/**
Strips the last component from a given $path.

If a path ends with one or more separators removes them first.
Returns "." if the path doesn't contain any path separators (after having
  removed trailing separators).
*/
dirname path/string --path_platform/string=platform -> string:
  search_path := path
  if path_platform == PLATFORM_WINDOWS:
    search_path = search_path.replace --all "\\" "/"
  while true:
    index := search_path.index_of --last "/"
    if index < 0: return "."
    if index != search_path.size - 1:
      // Note that we return a slice of the original path here, not the
      // search_path.
      return path[0..index]
    search_path = search_path[0..index]

/**
Creates a path relative to the given $base path.
*/
join base/string path/string --path_platform/string=platform -> string:
  if is_rooted path: return path
  if path_platform == PLATFORM_WINDOWS:
    if base.size == 2 and base[1] == ':':
      // If the base is really just a drive letter, then we must not add a separator.
      return canonicalize "$base$path"
  return canonicalize "$base/$path"

/**
Canonicalizes a path.
*/
canonicalize path/string --path_platform/string=platform -> string:
  start_index := 0
  if path_platform == PLATFORM_WINDOWS:
    if path.starts_with "//" or path.starts_with "\\\\":
      // UNC (Network) path.
      // We have to keep the first two slashes.
      // For simplicity we treat it like an absolute path with one
      // forward slash (ignoring the '/' at position 0).
      start_index = 1
    else if path.size > 2 and path[1] == ':':
      // Drive letter path.
      // We have to keep the drive letter and the colon.
      // Anything after that is treated like a normal (potentially absolute) path.
      start_index = 2

    // On Windows both separators ('/' and '\') are valid.
    // We always use forward slashes.
    // Note that we do this replacement only after we looked for '//' and '\\' as
    // '/\'' and '\/' are not valid UNC paths.
    path = path.replace --all "\\" "/"

  // Add a terminating character so we don't need to check for out of bounds.
  path_size := path.size
  bytes := ByteArray path_size + 1
  bytes.replace 0 path

  is_absolute := bytes[start_index] == '/'

  slashes := []  // Indexes of previous slashes.
  at_slash := false
  if not is_absolute:
    // For simplicity treat this as if we just encountered a slash.
    at_slash = true
    slashes.add -1

  target_index := start_index

  i := start_index
  while i < path_size:
    if at_slash and bytes[i] == '/':
      // Skip consecutive slashes.
      i++
      continue
    if at_slash and bytes[i] == '.' and (bytes[i + 1] == '/' or bytes[i + 1] == '\0'):
      // Drop "./" segments.
      i += 2
      continue
    if at_slash and
        bytes[i] == '.' and
        bytes[i + 1] == '.' and
        (bytes[i + 2] == '/' or bytes[i + 2] == '\0'):
      // Discard the previous segment (between the last two slashes).
      if slashes.size < 2:
        // We don't have a previous segment to discard.
        if is_absolute:
          // Just drop them if the path is absolute.
          i += 3
          continue
        // Otherwise we have to copy them over.
        bytes[target_index++] = bytes[i++]
        bytes[target_index++] = bytes[i++]
        bytes[target_index++] = bytes[i++]
        // It's not a problem if 'target_index' is one after the '\0' (equal to
        // 'bytes.size'), but it feels cleaner (and more resistant to future
        // changes) if we fix it.
        if target_index > path_size: target_index--
        continue
      // Still handling '..' here.
      // Reset to the last '/'.
      slashes.resize (slashes.size - 1)
      target_index = slashes.last + 1
      i += 3
      continue

    if bytes[i] == '/':
      slashes.add target_index
      at_slash = true
    else:
      at_slash = false

    bytes[target_index++] = bytes[i++]

  if target_index == 0: return "."
  // Drop trailing path separator unless it's the root path.
  last_char_index := target_index - 1
  if last_char_index > start_index and bytes[last_char_index] == '/':
    target_index--

  return bytes[..target_index].to_string
