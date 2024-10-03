#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate-roots
import cli show *
import log
import artemis.cli.pod-specification show PodSpecification INITIAL-POD-SPECIFICATION
import artemis.cli.sdk show get-sdk
import artemis.cli.firmware show get-envelope
import host.file
import snapshot show cache-snapshot
import supabase
import system

import .utils

main args/List:
  // Use the same application name as the
  // This way we get the same config and cache.
  // The config gives as the server configurations and oauth tokens.
  // The cache the SDKs.
  cli := Cli "artemis" --ui=(Ui.from-args args)
  main args --cli=cli

main args/List --cli/Cli?:
  certificate-roots.install-all-trusted-roots

  cmd := Command "sdk downloader"
      --help="Downloads SDKs and envelopes into the cache."
      --options=[
        Option "version"
            --help="The version of the SDK to use."
            --required,
        Option "envelope"
            --help="The envelope to download."
            --multi
            --split-commas,
        Flag "host-envelope"
            --help="Compute the envelope for this host and add it as 'envelope' option.",
      ]

  download-cmd := Command "download"
      --help="Caches SDKs and envelopes."
      --run=:: download it
  cmd.add download-cmd

  print-cmd := Command "print"
      --help="""
        Prints the path to the SDK or envelope.

        If necessary, downloads it first.
        """
      --options=[
        Option "envelope"
            --help="Prints the path to the envelope.",
        Flag "host-envelope"
            --help="Prints the path to the envelope that runs on the current host.",
      ]
      --run=:: print-path it
  cmd.add print-cmd

  cmd.run args --cli=cli

pod-specification-for_ --sdk-version/string --envelope/string --cli/Cli:
  json := INITIAL-POD-SPECIFICATION
  json["sdk-version"] = sdk-version
  json["firmware-envelope"] = envelope
  return PodSpecification.from-json json --path="ignored" --cli=cli

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

download invocation/Invocation:
  cli := invocation.cli

  sdk-version := invocation["version"]
  envelopes := invocation["envelope"]
  needs-host-envelope := invocation["host-envelope"]
  if needs-host-envelope:
    envelopes += [compute-host-envelope]

  get-sdk sdk-version --cli=cli
  envelopes.do:
    pod-specification := pod-specification-for_ --sdk-version=sdk-version --envelope=it --cli=cli
    get-envelope --specification=pod-specification --cli=cli

print-path invocation/Invocation:
  sdk-version := invocation["version"]
  envelope := invocation["envelope"]

  cli := invocation.cli
  ui := cli.ui

  needs-host-envelope := invocation["host-envelope"]
  if needs-host-envelope:
    if envelope: ui.abort "The options 'envelope' and '--host-envelope' are exclusive"
    envelope = compute-host-envelope

  // Use a different ui, to avoid printing anything.
  silent-ui := ui.with --level=Ui.SILENT-LEVEL
  silent-cli := cli.with --ui=silent-ui
  path/string := ?
  if envelope:
    pod-specification := pod-specification-for_
        --sdk-version=sdk-version
        --envelope=envelope
        --cli=silent-cli
    path = get-envelope --specification=pod-specification --cli=silent-cli
  else:
    path = (get-sdk sdk-version --cli=silent-cli).sdk-path

  ui.emit --result path
