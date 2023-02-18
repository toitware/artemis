// Copyright (C) 2023 Toitware ApS. All rights reserved.

// TODO(florian): make this library available in the host package?

/**
Whether the given $path is absolute.

On Windows the term "fully qualified" is often used for absolute paths.
*/
is_absolute path/string -> bool:
  if platform == PLATFORM_WINDOWS:
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
is_rooted path/string -> bool:
  if is_absolute path: return true
  if platform != PLATFORM_WINDOWS: return false
  if path.starts_with "\\" or path.starts_with "/": return true
  return path.size > 2 and path[1] == ':'

/**
Whether the given $path is relative.

A path is relative if it is not rooted.
*/
is_relative path/string -> bool:
  return not is_rooted path
