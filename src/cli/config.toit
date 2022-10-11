// Copyright (C) 2022 Toitware ApS. All rights reserved.

/**
Loads configurations.

Typically, configurations are layered. For example:
- System: \$(prefix)/etc/XXXconfig
- Global: \$XDG_CONFIG_HOME/XXX/config or ~/.XXXconfig. By default \$XDG_CONFIG_HOME is
  set to \$(HOME).
- Local: \$XXX_DIR/config

For now, only "global" (the ones from the home directory) are implemented.
*/

import host.os
import host.file
import host.directory
import encoding.json
import writer

APP_NAME ::= "artemis"

class Config:
  path/string
  data/Map

  constructor .path .data:

  /**
  Wether the configuration contains the given $key.

  The key is split on dots, and the value is searched for in the nested map.
  */
  contains key/string -> bool:
    parts := key.split "."
    current := data
    parts.do:
      if current is not Map: return false
      if current.contains it: current = current[it]
      else: return false
    return true

  /**
  Sets the given $key to $value.

  The key is split on dots, and the value is set in the nested map.
  */
  operator[]= key/string value/any -> none:
    parts := key.split "."
    current := data
    parts[.. parts.size - 1].do:
      if current is not Map: throw "Cannot set $key: Path contains non-map."
      if current.contains it: current = current[it]
      new_map := {:}
      current[it] = new_map
      current = new_map
    current[parts.last] = value

  /**
  Gets the value for the given $key.
  Returns null if the $key isn't present.

  The key is split on dots, and the value is searched for in the nested map.
  */
  get key/string -> any:
    parts := key.split "."
    result := data
    for i := 0; i < parts.size; i++:
      part_key := parts[i]
      if result is not Map:
        throw "Invalid key. $(parts[.. i - 1].join ".") is not a map"
      if result.contains part_key:
        result = result[part_key]
      else:
        return null
    return result

  /**
  Writes the configuration to the file that was specified during constructions.
  */
  write:
    write_config_file path data

  /**
  Writes the configuration to the given $override_path.
  */
  write override_path/string:
    write_config_file override_path data

/**
Reads the configuration for $APP_NAME.
Uses an empty map if no configuration is found.
*/
read_config -> Config:
  return read_config --init=: {:}

/**
Reads the configuration for $APP_NAME.
Calls $init if no configuration is found and uses it as initial configuration.

This function looks for the configuration file in the following places:
- If the environment variable APP_CONFIG (where "APP" is the uppercased version of
  $APP_NAME) is set, uses it as the path to the configuration file.
- CONFIG_HOME/$APP_NAME/config where CONFIG_HOME is either equal to the environment
  variable XDG_CONFIG_HOME (if set), and \$HOME/.config otherwise.
- The directories given in \$XDG_CONFIG_DIRS (separated by ':').
*/
read_config [--init] -> Config:
  app_name_upper := APP_NAME.to_ascii_upper
  env := os.env
  if env.contains "$(app_name_upper)_CONFIG":
    return read_config_file env["$(app_name_upper)_CONFIG"] --init=init

  config_dirs := []
  if env.contains "XDG_CONFIG_HOME":
    config_dirs.add env["XDG_CONFIG_HOME"]
  else if env.contains "HOME":
    config_dirs.add "$env["HOME"]/.config"

  if env.contains "XDG_CONFIG_DIRS":
    config_dirs.add_all (env["XDG_CONFIG_DIRS"].split ":")

  if config_dirs.is_empty: throw "No config directories found. HOME not set."

  config_dirs.do: | dir |
    path := "$(dir)/$(APP_NAME)/config"
    if file.is_file path:
      return read_config_file path --init=init

  return read_config_file "$config_dirs[0]/$APP_NAME/config" --init=init

/**
Reads the configuration from the given $path.
*/
read_config_file path/string [--init] -> Config:
  if not file.is_file path:
    data := {:}
    data = init.call data
    return Config path data
  content := file.read_content path
  parsed := json.decode content
  return Config path parsed

/**
Writes the configuration map $data to the given $path.
*/
write_config_file path/string data/Map:
  if path.contains "/":
    last := path.index_of --last "/"
    dir := path[..last]
    directory.mkdir --recursive dir

  content := json.encode data
  stream := file.Stream.for_write path
  try:
    writer := writer.Writer stream
    writer.write content
  finally:
    stream.close
