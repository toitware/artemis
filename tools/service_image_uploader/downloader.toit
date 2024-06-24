#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate-roots
import cli
import io
// TODO(florian): these should come from the cli package.
import artemis.cli.config as cli
import artemis.cli.cache as cli
import artemis.cli.sdk show *
import artemis.cli.ui show *
import host.file
import snapshot show cache-snapshot
import supabase
import supabase.filter show equals

import .client show AR-SNAPSHOT-HEADER
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
  certificate-roots.install-all-trusted-roots

  cmd := cli.Command "downloader"
      --help="""
        Downloads snapshots from the Artemis server and stores them in the Jaguar cache.

        The snapshots can be filtered by SDK version and service version for service
        snapshots. There is no way to filter by CLI version.

        If no arguments are given, all snapshots are downloaded.
        """
      --options=[
        cli.OptionString "sdk-version"
            --help="The version of the SDK to use.",
        cli.OptionString "service-version"
            --help="The version of the service to use.",
        cli.OptionString "output-directory"
            --help="The directory to store the downloaded snapshots in.",
        cli.OptionString "server"
            --help="The server to download from.",
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

  with-supabase-client parsed config ui: | client/supabase.Client |
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
      // We only download a snapshot if we don't have it in our Artemis cache.
      // This means that it is possible to remove a snapshot from the snapshot-directory
      // and not get it back by calling this function (since the Artemis cache
      // would still be there).
      // In that case, one would need to remove the Artemis cache.
      snapshot := cache.get cache-key: | store/cli.FileStore |
        ui.info "Downloading $row["sdk_version"]-$row["service_version"]."
        snapshot/ByteArray? := null
        exception := catch:
          snapshot = client.storage.download --path="service-snapshots/$image"
        if exception:
          ui.error "Failed to download $row["sdk_version"]-$row["service_version"]."
          ui.error "Are you logged in as an admin?"
          ui.error exception
          ui.abort

        ar-reader := ar.ArReader (io.Reader snapshot)
        artemis-header := ar-reader.find AR-SNAPSHOT-HEADER
        if not artemis-header:
          // Deprecated direct snapshot format.
          uuid := cache-snapshot snapshot --output-directory=output-directory
          ui.info "Wrote service snapshot $uuid."
        else:
          // Reset the reader.
          // We are right after the header, which should be the first file.
          // Since we don't need the header anymore (and we will in fact skip it),
          // we could just continue reading, but by resetting we avoid hard-to-find bugs.
          ar-reader = ar.ArReader (io.Reader snapshot)
          while file/ar.ArFile? := ar-reader.next:
            if file.name == AR-SNAPSHOT-HEADER:
              continue
            uuid := cache-snapshot file.content --output-directory=output-directory
            ui.info "Wrote service snapshot $uuid."
        store.save snapshot

    if not sdk-version and not service-version:
      // Download all CLI snapshots.
      available-snapshots := client.storage.list "cli-snapshots"
      available-snapshots.do: | file-description/Map |
        name := file-description["name"]
        cache-key := "snapshot-downloader/$name"
        // Same as above: we only download/write snapshots if we don't have any
        // entry in the Artemis cache. If the snapshot files have been deleted,
        // then one might need to remove the Artemis cache.
        cache.get cache-key: | store/cli.FileStore |
          ui.info "Downloading $name."
          snapshot := client.storage.download --path="cli-snapshots/$name"
          uuid := cache-snapshot snapshot --output-directory=output-directory
          ui.info "Wrote CLI snapshot $uuid."
          store.save snapshot
