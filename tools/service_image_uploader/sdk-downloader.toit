#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate-roots
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
import system

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
  certificate-roots.install-all-trusted-roots

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
        cli.Flag "host-envelope"
            --help="Compute the envelope for this host and add it as 'envelope' option.",
      ]

  download-cmd := cli.Command "download"
      --help="Caches SDKs and envelopes."
      --run=:: download config cache ui it
  cmd.add download-cmd

  print-cmd := cli.Command "print"
      --help="""
        Prints the path to the SDK or envelope.

        If necessary, downloads it first.
        """
      --options=[
        cli.Option "envelope"
            --help="Prints the path to the envelope.",
        cli.Flag "host-envelope"
            --help="Prints the path to the envelope that runs on the current host.",
      ]
      --run=:: print-path config cache ui it
  cmd.add print-cmd

  cmd.run args

pod-specification-for_ --sdk-version/string --envelope/string --ui/ui.Ui:
  json := INITIAL-POD-SPECIFICATION
  json["sdk-version"] = sdk-version
  json["firmware-envelope"] = envelope
  return PodSpecification.from-json json --path="ignored" --ui=ui

compute-host-envelope -> string:
  arch := system.architecture
  platform := system.platform
  if platform == system.PLATFORM-WINDOWS:
    if arch == system.ARCHITECTURE-X86-64: return "x64-windows"
  else if platform == system.PLATFORM-LINUX:
    if arch == system.ARCHITECTURE-X86-64: return "x64-linux"
  else if platform == system.PLATFORM-MACOS:
    if arch == system.ARCHITECTURE-X86-64: return "x64-macos"
    if arch == system.ARCHITECTURE-ARM64: return "aarch64-macos"
  throw "Unsupported architecture: $arch - $platform"

download config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  sdk-version := parsed["version"]
  envelopes := parsed["envelope"]
  needs-host-envelope := parsed["host-envelope"]
  if needs-host-envelope:
    envelopes += [compute-host-envelope]

  get-sdk --cache=cache sdk-version --ui=ui
  envelopes.do:
    pod-specification := pod-specification-for_ --sdk-version=sdk-version --envelope=it --ui=ui
    get-envelope --specification=pod-specification --cache=cache --ui=ui

class SilentUi extends ui.Ui:
  result-ui/ui.Ui

  constructor .result-ui:
    super --level=ui.Ui.SILENT-LEVEL

  create-printer_ prefix/string? kind/int -> ui.Printer:
    return result-ui.create-printer_ prefix kind

  wants-structured-result -> bool:
    return result-ui.wants-structured-result

print-path config/cli.Config cache/cli.Cache result-ui/ui.Ui parsed/cli.Parsed:
  sdk-version := parsed["version"]
  envelope := parsed["envelope"]
  needs-host-envelope := parsed["host-envelope"]
  if needs-host-envelope:
    if envelope: result-ui.abort "The options 'envelope' and '--host-envelope' are exclusive"
    envelope = compute-host-envelope

  // Use a different ui, to avoid printing anything.
  silent-ui := SilentUi result-ui
  path/string := ?
  if envelope:
    pod-specification := pod-specification-for_
        --sdk-version=sdk-version
        --envelope=envelope
        --ui=silent-ui
    path = get-envelope --cache=cache --specification=pod-specification --ui=silent-ui
  else:
    path = (get-sdk --cache=cache sdk-version --ui=silent-ui).sdk-path

  result-ui.result path
