#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate-roots
import cli show *
import io
import host.file
import snapshot show cache-snapshot
import supabase
import supabase.filter show equals

import .client show AR-SNAPSHOT-HEADER
import .utils

main args/List:
  // Use the same application name as the
  // This way we get the same config and cache.
  // The config gives as the server configurations and oauth tokens.
  // The cache the SDKs.
  cli := Cli "artemis"
  main args --cli=cli

main args/List --cli/Cli?:
  certificate-roots.install-all-trusted-roots

  cmd := Command "downloader"
      --help="""
        Downloads snapshots from the Artemis server and stores them in the Jaguar cache.

        The snapshots can be filtered by SDK version and service version for service
        snapshots. There is no way to filter by CLI version.

        If no arguments are given, all snapshots are downloaded.
        """
      --options=[
        Option "sdk-version"
            --help="The version of the SDK to use.",
        Option "service-version"
            --help="The version of the service to use.",
        Option "output-directory"
            --help="The directory to store the downloaded snapshots in.",
        Option "server"
            --help="The server to download from.",
      ]
      --examples=[
        Example "Download all snapshots:" --arguments="",
        Example """
          Download the snapshot for service snapshot v0.1.0 and SDK version v2.0.0-alpha.62:"""
          --arguments="--service-version=v0.1.0 --sdk-version=v2.0.0-alpha.62",
      ]
      --run=:: download it

  cmd.run args --cli=cli

download invocation/Invocation:
  sdk-version := invocation["sdk-version"]
  service-version := invocation["service-version"]
  output-directory := invocation["output-directory"]

  cli := invocation.cli
  ui := cli.ui

  with-supabase-client invocation: | client/supabase.Client |
    client.ensure-authenticated: ui.emit --error it

    // Get a list of snapshots to download.
    filters := []
    if sdk-version: filters.add (equals "sdk_version" "$sdk-version")
    if service-version: filters.add (equals "service_version" "$service-version")
    service-images := client.rest.select "sdk_service_versions" --filters=filters
    ui.emit --info "Downloading snapshots for:"
    ui.emit-table --info
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
      snapshot := cli.cache.get cache-key: | store/FileStore |
        ui.emit --info "Downloading $row["sdk_version"]-$row["service_version"]."
        snapshot/ByteArray? := null
        exception := catch:
          snapshot = client.storage.download --path="service-snapshots/$image"
        if exception:
          ui.emit --error "Failed to download $row["sdk_version"]-$row["service_version"]."
          ui.emit --error "Are you logged in as an admin?"
          ui.emit --error exception
          ui.abort

        ar-reader := ar.ArReader (io.Reader snapshot)
        artemis-header := ar-reader.find AR-SNAPSHOT-HEADER
        if not artemis-header:
          // Deprecated direct snapshot format.
          uuid := cache-snapshot snapshot --output-directory=output-directory
          ui.emit --info "Wrote service snapshot $uuid."
        else:
          // Reset the reader.
          // We are right after the header, which should be the first file.
          // Since we don't need the header anymore (and we will in fact skip it),
          // we could just continue reading, but by resetting we avoid hard-to-find bugs.
          ar-reader = ar.ArReader (io.Reader snapshot)
          while file/ar.ArFile? := ar-reader.next:
            if file.name == AR-SNAPSHOT-HEADER:
              continue
            uuid := cache-snapshot file.contents --output-directory=output-directory
            ui.emit --info "Wrote service snapshot $uuid."
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
        cli.cache.get cache-key: | store/FileStore |
          ui.emit --info "Downloading $name."
          snapshot := client.storage.download --path="cli-snapshots/$name"
          uuid := cache-snapshot snapshot --output-directory=output-directory
          ui.emit --info "Wrote CLI snapshot $uuid."
          store.save snapshot
