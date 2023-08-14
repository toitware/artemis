#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
// TODO(florian): these should come from the cli package.
import artemis.cli.config as cli
import artemis.cli.cache as cli
import artemis.cli.sdk show *
import artemis.cli.ui show *
import host.file
import snapshot show cache-snapshot
import supabase
import supabase.filter show equals

import .utils

main args:
  // Use the same config as the CLI.
  // This way we get the same server configurations and oauth tokens.
  config := cli.read-config
  // Use the same cache as the CLI.
  // This way we can reuse the SDKs.
  cache := cli.Cache --app-name="artemis"
  ui := ConsoleUi

  main --config=config --cache=cache --ui=ui args

main --config/cli.Config --cache/cli.Cache --ui/Ui args:
  cmd := cli.Command "downloader"
      --long-help="""
        Downloads snapshots from the Artemis server and stores them in the Jaguar cache.

        The snapshots can be filtered by SDK version and service version for service
        snapshots. There is no way to filter by CLI version.

        If no arguments are given, all snapshots are downloaded.
        """
      --options=[
        cli.OptionString "sdk-version"
            --short-help="The version of the SDK to use.",
        cli.OptionString "service-version"
            --short-help="The version of the service to use.",
        cli.OptionString "output-directory"
            --short-help="The directory to store the downloaded snapshots in.",
        cli.OptionString "server"
            --short-help="The server to download from.",
      ]
      --examples=[
        cli.Example "Download all snapshots:" --arguments="",
        cli.Example """
          Download the snapshot for service snapshot v0.1.0 and SDK version v2.0.0-alpha.62:"""
          --arguments="--service-version=v0.1.0 --sdk-version=v2.0.0-alpha.62",
      ]
      --run=:: download config cache ui it
  cmd.run args

download config/cli.Config cache/cli.Cache ui/Ui parsed/cli.Parsed:
  sdk-version := parsed["sdk-version"]
  service-version := parsed["service-version"]
  output-directory := parsed["output-directory"]

  with-supabase-client parsed config: | client/supabase.Client |
    client.ensure-authenticated: it.sign-in --provider="github" --ui=ui

    // Get a list of snapshots to download.
    filters := []
    if sdk-version: filters.add (equals "sdk_version" "$sdk-version")
    if service-version: filters.add (equals "service_version" "$service-version")
    service-images := client.rest.select "sdk_service_versions" --filters=filters
    ui.info "Downloading snapshots for:"
    ui.do --kind=Ui.INFO: | printer/Printer |
      printer.emit
          --header={"sdk_version": "SDK", "service_version": "Service"}
          service-images

    service-images.do: | row |
      image := row["image"]
      cache-key := "snapshot-downloader/$image"
      snapshot := cache.get cache-key: | store/cli.FileStore |
        ui.info "Downloading $row["sdk_version"]-$row["service_version"]."
        exception := catch:
          store.save (client.storage.download --path="service-snapshots/$image")
        if exception:
          ui.error "Failed to download $row["sdk_version"]-$row["service_version"]."
          ui.error "Are you logged in as an admin?"
          ui.error exception
          ui.abort

      uuid := cache-snapshot snapshot --output-directory=output-directory
      ui.info "Wrote service snapshot $uuid."

    if not sdk-version and not service-version:
      // Download all CLI snapshots.
      available-snapshots := client.storage.list "cli-snapshots"
      available-snapshots.do: | file-description/Map |
        name := file-description["name"]
        cache-key := "snapshot-downloader/$name"
        snapshot := cache.get cache-key: | store/cli.FileStore |
          ui.info "Downloading $name."
          store.save (client.storage.download --path="cli-snapshots/$name")

        uuid := cache-snapshot snapshot --output-directory=output-directory
        ui.info "Wrote CLI snapshot $uuid."
