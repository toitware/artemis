// Copyright (C) 2022 Toitware ApS. All rights reserved.

import expect show *
import artemis.cli.config as cfg
import .utils

main:
  with_tmp_directory: | tmp_dir |
    config_file := "$tmp_dir/config"
    config := cfg.Config config_file {:}

    // All `get` commands return 'null' if the value doesn't exist yet.
    expect_null (config.get "foo")
    expect_null (config.get "foo.bar")
    expect_null (config.get "foo.bar.baz")

    // Initial a non existing value with the `--init` function.
    // Note that the key is split on dots, and intermediate maps
    // are created.
    initial := config.get "foo.bar.baz" --init=:"qux"
    expect_equals "qux" initial
    expect (config.get "foo") is Map
    expect (config.get "foo.bar") is Map
    expect_equals "qux" (config.get "foo.bar.baz")

    // Overwrite the value with an operator.
    config["foo.bar.baz"] = "quux"
    expect_equals "quux" (config.get "foo.bar.baz")

    // Create a new value with the operator.
    config["foo.bar.gee"] = 499
    expect_equals 499 (config.get "foo.bar.gee")

    config["foo.bar.gee"] = 500

    config.write

    // Read the config back in.
    config2 := cfg.read_config_file config_file --init=: unreachable

    expect (deep_equals config.data config2.data)

deep_equals a/any b/any:
  if a is Map:
    if b is not Map: return false
    if a.size != b.size: return false
    a.do: | key value |
      if not b.contains key: return false
      if not deep_equals value b[key]: return false
    return true

  if a is List:
    if b is not List: return false
    if a.size != b.size: return false
    a.size.repeat:
      if not deep_equals a[it] b[it]: return false
    return true

  return a == b
