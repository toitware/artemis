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
import supabase
import fs.xdg
import fs
import .utils

APP_NAME ::= "artemis"
CONFIG_DEVICE_DEFAULT_KEY ::= "device.default"
CONFIG_BROKER_DEFAULT_KEY ::= "server.broker.default"
CONFIG_ARTEMIS_DEFAULT_KEY ::= "server.artemis.default"
CONFIG_SERVERS_KEY ::= "servers"
CONFIG_SERVER_AUTHS_KEY ::= "auths"
CONFIG_ORGANIZATION_DEFAULT ::= "organization.default"

class ConfigLocalStorage implements supabase.LocalStorage:
  config_/Config
  auth_key_/string

  constructor .config_ --auth_key/string="":
    auth_key_ = auth_key

  has_auth -> bool:
    return config_.contains auth_key_

  get_auth -> any?:
    return config_.get auth_key_

  set_auth value/any:
    config_[auth_key_] = value
    config_.write

  remove_auth -> none:
    config_.remove auth_key_
    config_.write

/*------ TODO(florian): the code below should be moved into the CLI package. ------*/

class Config:
  path/string
  data/Map

  constructor .path .data:

  /**
  Whether the configuration contains the given $key.

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
      current = current.get it --init=: {:}
    current[parts.last] = value

  /**
  Removes the value for the given $key.
  */
  remove key/string -> none:
    parts := key.split "."
    current := data
    parts[.. parts.size - 1].do:
      if current is not Map: return
      if current.contains it: current = current[it]
      else: return
    current.remove parts.last

  /**
  Gets the value for the given $key.
  Returns null if the $key isn't present.

  The key is split on dots, and the value is searched for in the nested map.
  */
  get key/string -> any:
    return get_ key --no-initialize_if_missing --init=: unreachable

  /**
  Variant of $(get key).

  Calls $init if the $key isn't present, and stores the result as initial
    value.

  Creates all intermediate maps if they don't exist.
  */
  get key/string [--init] -> any:
    return get_ key --initialize_if_missing --init=init

  get_ key/string --initialize_if_missing/bool [--init]:
    parts := key.split "."
    result := data
    for i := 0; i < parts.size; i++:
      part_key := parts[i]
      if result is not Map:
        throw "Invalid key. $(parts[.. i - 1].join ".") is not a map"
      result = result.get part_key --init=:
        if not initialize_if_missing: return null
        i != parts.size - 1 ? {:} : init.call
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

  config_home := xdg.config_home
  // Hackish way to improve the developer experience.
  // When using the toit files to run Artemis, we default to a different
  // configuration.
  if is_dev_setup:
    return read_config_file "$config_home/artemis-dev/config" --init=init

  // The path we are using to write configurations to.
  app_config_path := "$config_home/$APP_NAME/config"
  if file.is_file app_config_path:
    return read_config_file app_config_path --init=init

  // Try to find a configuration file in the XDG config directories.
  xdg.config_dirs.do: | dir |
    path := "$dir/$APP_NAME/config"
    if file.is_file path:
      from_config_dir := read_config_file path --init=init
      return Config app_config_path from_config_dir.data

  return read_config_file app_config_path --init=init

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
  directory.mkdir --recursive (fs.dirname path)

  content := json.encode data
  stream := file.Stream.for_write path
  try:
    writer := writer.Writer stream
    writer.write content
  finally:
    stream.close
