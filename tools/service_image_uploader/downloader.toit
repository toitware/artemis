#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
// TODO(florian): these should come from the cli package.
import artemis.cli.config as cli
import artemis.cli.cache as cli
import artemis.cli.sdk show *
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
  cmd := cli.Command "downloader"
      --long_help="""
        Downloads snapshots from the Artemis server and stores them in the Jaguar cache.

        The snapshots can be filtered by SDK version and service version for service
        snapshots. There is no way to filter by CLI version.

        If no arguments are given, all snapshots are downloaded.
        """
      --options=[
        cli.OptionString "sdk-version"
            --short_help="The version of the SDK to use.",
        cli.OptionString "service-version"
            --short_help="The version of the service to use.",
        cli.OptionString "output-directory"
            --short_help="The directory to store the downloaded snapshots in.",
        cli.OptionString "server"
            --short_help="The server to download from.",
      ]
      --examples=[
        cli.Example "Download all snapshots:" --arguments="",
        cli.Example """
          Download the snapshot for service snapshot v0.1.0 and SDK version v2.0.0-alpha.58:"""
          --arguments="--service-version=v0.1.0 --sdk-version=v2.0.0-alpha.58",
      ]
      --run=:: download config cache ui it
  cmd.run args

download config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  sdk_version := parsed["sdk-version"]
  service_version := parsed["service-version"]
  output_directory := parsed["output-directory"]

  with_supabase_client parsed config: | client/supabase.Client |
    client.ensure_authenticated: it.sign_in --provider="github" --ui=ui

    // Get a list of snapshots to download.
    filters := []
    if sdk_version: filters.add "sdk_version=eq.$sdk_version"
    if service_version: filters.add "service_version=eq.$service_version"
    service_images := client.rest.select "sdk_service_versions" --filters=filters
    ui.info "Downloading snapshots for:"
    ui.info_table --header=[ "SDK", "Service" ]
      service_images.map: | row | [ row["sdk_version"], row["service_version"] ]

    service_images.do: | row |
      image := row["image"]
      cache_key := "snapshot-downloader/$image"
      snapshot := cache.get cache_key: | store/cli.FileStore |
        ui.info "Downloading $row["sdk_version"]-$row["service_version"]"
        store.save (client.storage.download --path="service-snapshots/$image")

      uuid := cache_snapshot snapshot --output_directory=output_directory
      ui.info "Wrote service snapshot $uuid"

    if not sdk_version and not service_version:
      // Download all CLI snapshots.
      available_snapshots := client.storage.list "cli-snapshots"
      available_snapshots.do: | file_description/Map |
        name := file_description["name"]
        cache_key := "snapshot-downloader/$name"
        snapshot := cache.get cache_key: | store/cli.FileStore |
          ui.info "Downloading $name"
          store.save (client.storage.download --path="cli-snapshots/$name")

        uuid := cache_snapshot snapshot --output_directory=output_directory
        ui.info "Wrote CLI snapshot $uuid"
