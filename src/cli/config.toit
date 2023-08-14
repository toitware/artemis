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

APP-NAME ::= "artemis"

// When adding a new config don't forget to update the 'config show' command.
CONFIG-DEVICE-DEFAULT-KEY ::= "device.default"
CONFIG-BROKER-DEFAULT-KEY ::= "server.broker.default"
CONFIG-ARTEMIS-DEFAULT-KEY ::= "server.artemis.default"
CONFIG-SERVERS-KEY ::= "servers"
CONFIG-SERVER-AUTHS-KEY ::= "auths"
CONFIG-ORGANIZATION-DEFAULT-KEY ::= "organization.default"
// When adding a new config don't forget to update the 'config show' command.

class ConfigLocalStorage implements supabase.LocalStorage:
  config_/Config
  auth-key_/string

  constructor .config_ --auth-key/string="":
    auth-key_ = auth-key

  has-auth -> bool:
    return config_.contains auth-key_

  get-auth -> any?:
    return config_.get auth-key_

  set-auth value/any:
    config_[auth-key_] = value
    config_.write

  remove-auth -> none:
    config_.remove auth-key_
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
    return get_ key --no-initialize-if-absent --init=: unreachable

  /**
  Variant of $(get key).

  Calls $init if the $key isn't present, and stores the result as initial
    value.

  Creates all intermediate maps if they don't exist.
  */
  get key/string [--init] -> any:
    return get_ key --initialize-if-absent --init=init

  get_ key/string --initialize-if-absent/bool [--init]:
    parts := key.split "."
    result := data
    for i := 0; i < parts.size; i++:
      part-key := parts[i]
      if result is not Map:
        throw "Invalid key. $(parts[.. i - 1].join ".") is not a map"
      result = result.get part-key --init=:
        if not initialize-if-absent: return null
        i != parts.size - 1 ? {:} : init.call
    return result

  /**
  Writes the configuration to the file that was specified during constructions.
  */
  write:
    write-config-file path data

  /**
  Writes the configuration to the given $override-path.
  */
  write override-path/string:
    write-config-file override-path data

/**
Reads the configuration for $APP-NAME.
Uses an empty map if no configuration is found.
*/
read-config -> Config:
  return read-config --init=: {:}

/**
Reads the configuration for $APP-NAME.
Calls $init if no configuration is found and uses it as initial configuration.

This function looks for the configuration file in the following places:
- If the environment variable APP_CONFIG (where "APP" is the uppercased version of
  $APP-NAME) is set, uses it as the path to the configuration file.
- CONFIG_HOME/$APP-NAME/config where CONFIG_HOME is either equal to the environment
  variable XDG_CONFIG_HOME (if set), and \$HOME/.config otherwise.
- The directories given in \$XDG_CONFIG_DIRS (separated by ':').
*/
read-config [--init] -> Config:
  app-name-upper := APP-NAME.to-ascii-upper
  env := os.env
  if env.contains "$(app-name-upper)_CONFIG":
    return read-config-file env["$(app-name-upper)_CONFIG"] --init=init

  config-home := xdg.config-home
  // Hackish way to improve the developer experience.
  // When using the toit files to run Artemis, we default to a different
  // configuration.
  if is-dev-setup:
    return read-config-file "$config-home/artemis-dev/config" --init=init

  // The path we are using to write configurations to.
  app-config-path := "$config-home/$APP-NAME/config"
  if file.is-file app-config-path:
    return read-config-file app-config-path --init=init

  // Try to find a configuration file in the XDG config directories.
  xdg.config-dirs.do: | dir |
    path := "$dir/$APP-NAME/config"
    if file.is-file path:
      from-config-dir := read-config-file path --init=init
      return Config app-config-path from-config-dir.data

  return read-config-file app-config-path --init=init

/**
Reads the configuration from the given $path.
*/
read-config-file path/string [--init] -> Config:
  if not file.is-file path:
    data := {:}
    data = init.call data
    return Config path data
  content := file.read-content path
  parsed := json.decode content
  return Config path parsed

/**
Writes the configuration map $data to the given $path.
*/
write-config-file path/string data/Map:
  directory.mkdir --recursive (fs.dirname path)

  content := json.encode data
  stream := file.Stream.for-write path
  try:
    writer := writer.Writer stream
    writer.write content
  finally:
    stream.close
