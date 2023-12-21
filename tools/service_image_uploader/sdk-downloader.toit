#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import log
// TODO(florian): these should come from the cli package.
import artemis.cli.config as cli
import artemis.cli.cache as cli
import artemis.cli.sdk show *
import artemis.cli.firmware show *
import artemis.cli.pod-specification show PodSpecification INITIAL-POD-SPECIFICATION
import artemis.cli.ui as ui
import host.file
import snapshot show cache-snapshot
import supabase

import .utils

main args:
  // Use the same config as the CLI.
  // This way we get the same server configurations and oauth tokens.
  config := cli.read-config
  // Use the same cache as the CLI.
  // This way we can reuse the SDKs.
  cache := cli.Cache --app-name="artemis"
  ui := ui.ConsoleUi

  main --config=config --cache=cache --ui=ui args

main --config/cli.Config --cache/cli.Cache --ui/ui.Ui args:
  cmd := cli.Command "sdk downloader"
      --help="Downloads SDKs and envelopes into the cache."
      --options=[
        cli.Option "version"
            --help="The version of the SDK to use."
            --required,
        cli.Option "envelope"
            --help="The envelope to download."
            --multi
            --split-commas,
      ]

  download-cmd := cli.Command "download"
      --help="Caches SDKs and envelopes."
      --run=:: download config cache ui it
  cmd.add download-cmd

  print-cmd := cli.Command "print"
      --help="Prints the path to the SDK or envelope."
      --options=[
        cli.Option "envelope"
            --help="Prints the path to the envelope.",
      ]
      --run=:: print-path config cache ui it
  cmd.add print-cmd

  cmd.run args

pod-specification-for_ --sdk-version/string --envelope/string:
  json := INITIAL-POD-SPECIFICATION
  json["sdk-version"] = sdk-version
  json["firmware-envelope"] = envelope
  return PodSpecification.from-json json --path="ignored"

download config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  sdk-version := parsed["version"]
  envelopes := parsed["envelope"]

  get-sdk --cache=cache sdk-version
  envelopes.do:
    pod-specification := pod-specification-for_ --sdk-version=sdk-version --envelope=it
    get-envelope --specification=pod-specification --cache=cache

print-path config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  // Make sure we don't print anything while downloading.
  log.set-default (log.default.with-level log.FATAL-LEVEL)
  sdk-version := parsed["version"]
  envelope := parsed["envelope"]

  path/string := ?
  if envelope:
    pod-specification := pod-specification-for_ --sdk-version=sdk-version --envelope=envelope
    path = get-envelope --cache=cache --specification=pod-specification
  else:
    path = (get-sdk --cache=cache sdk-version).sdk-path

  ui.result path
