#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import log
// TODO(florian): these should come from the cli package.
import artemis.cli.config as cli
import artemis.cli.cache as cli
import artemis.cli.sdk show *
import artemis.cli.firmware show *
import artemis.cli.pod_specification show PodSpecification INITIAL_POD_SPECIFICATION
import artemis.cli.ui as ui
import host.file
import snapshot show cache_snapshot
import supabase

import .utils

main args:
  // Use the same config as the CLI.
  // This way we get the same server configurations and oauth tokens.
  config := cli.read_config
  // Use the same cache as the CLI.
  // This way we can reuse the SDKs.
  cache := cli.Cache --app_name="artemis"
  ui := ui.ConsoleUi

  main --config=config --cache=cache --ui=ui args

main --config/cli.Config --cache/cli.Cache --ui/ui.Ui args:
  cmd := cli.Command "sdk downloader"
      --long_help="Downloads SDKs and envelopes into the cache."
      --options=[
        cli.Option "version"
            --short_help="The version of the SDK to use."
            --required,
      ]

  download_cmd := cli.Command "download"
      --long_help="Caches SDKs and envelopes."
      --run=:: download config cache ui it
  cmd.add download_cmd

  print_cmd := cli.Command "print"
      --long_help="Prints the path to the SDK or envelope."
      --options=[
        cli.Flag "envelope"
            --short_help="Prints the path to the envelope.",
      ]
      --run=:: print_path config cache ui it
  cmd.add print_cmd

  cmd.run args

pod_specification_for_ --sdk_version/string:
  json := INITIAL_POD_SPECIFICATION
  json["sdk-version"] = sdk_version
  return PodSpecification.from_json json --path="ignored"

download config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  sdk_version := parsed["version"]

  get_sdk --cache=cache sdk_version
  pod_specification := pod_specification_for_ --sdk_version=sdk_version
  get_envelope --specification=pod_specification --cache=cache

print_path config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  // Make sure we don't print anything while downloading.
  log.set_default (log.default.with_level log.FATAL_LEVEL)
  sdk_version := parsed["version"]
  envelope := parsed["envelope"]

  path/string := ?
  if envelope:
    pod_specification := pod_specification_for_ --sdk_version=sdk_version
    path = get_envelope --cache=cache --specification=pod_specification
  else:
    path = (get_sdk --cache=cache sdk_version).sdk_path

  ui.result path
