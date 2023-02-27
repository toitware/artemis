// Copyright (C) 2023 Toitware ApS. All rights reserved.

// TODO(florian): move this library to the host package (or its own package?).

import host.os

/**
The XDG specification defines a set of environment variables that are used to
  locate user-specific directories for various purposes. This library provides
  access to some of these directories.

This library does not try to be smart about different operating systems. For
  example, it does not map the $config_home on macOS to the 'Library/Preferences'
  directory. Instead, it uses the \$XDG_CONFIG_HOME environment variable, and, if
  that is not set, falls back to the ~/.config directory. For command-line
  tools, this is more often the correct behavior. However, care must be taken
  when using the \$cache directory. Macos time machine will not back up files in
  '~/Library/Caches', but it will back up files in '~/.cache'. A good work-around
  is to symlink '~/.cache' to somewhere in '~/Library/Caches'.


The XDG specification is available at
  https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
*/

/**
Returns the value of the given $xdg_env_var_name.
If the environment variable is not set, then uses the given $fallback which
  is assumed to be relative to the user's home.
*/
from_env_ xdg_env_var_name/string --fallback/string -> string?:
  xdg_result := os.env.get xdg_env_var_name
  if xdg_result: return xdg_result

  // All fallbacks are relative to the user's home directory.
  home := os.env.get "HOME"
  if not home and platform == PLATFORM_WINDOWS:
    home = os.env.get "USERPROFILE"

  if not home: throw "Could not determine home directory."

  separator := platform == PLATFORM_WINDOWS ? "\\" : "/"
  return "$home$separator$fallback"

/**
The base directory relative to which user-specific data files should be stored.
*/
data_home -> string?:
  return from_env_ "XDG_DATA_HOME" --fallback=".local/share"

/**
The list of additional directories to look for data files in addition to
  $data_home.
*/
data_dirs -> List:
  dirs := os.env.get "XDG_DATA_DIRS"
  if not dirs: return ["/usr/local/share", "/usr/share"]
  return dirs.split ":"

/**
The base directory relative to which user-specific configuration files should be
  stored.
*/
config_home -> string?:
  return from_env_ "XDG_CONFIG_HOME" --fallback=".config"

/**
A list of additional directories to look for configuration files in addition to
  $config_home.
*/
config_dirs -> List:
  dirs := os.env.get "XDG_CONFIG_DIRS"
  if not dirs: return ["/etc/xdg"]
  return dirs.split ":"

/**
The base directory relative to which user-specific state files should be stored.

The state directory contains data that should be kept across program invocations,
  but is not important or portable enough to be stored in the $data_home.

Examples of data that might be stored in the state directory include:
- logs, recently used files, history, etc.
- the current state of the application on this machine (like the layout, undo history, etc.)
*/
state_home -> string?:
  return from_env_ "XDG_STATE_HOME" --fallback=".local/state"

/**
The base directory relative to which user-specific non-essential (cached) data
  should be stored.
*/
cache_home -> string?:
  return from_env_ "XDG_CACHE_HOME" --fallback=".cache"
