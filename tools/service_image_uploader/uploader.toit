#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import cli
import encoding.url as url-encoding

// TODO(florian): these should come from the cli package.
import artemis.cli.config as cli
import artemis.cli.cache as cli
import artemis.cli.cache show service-image-cache-key
import artemis.cli.git show Git
import artemis.cli.sdk show *
import artemis.cli.ui as ui
import artemis.shared.version show ARTEMIS-VERSION
import host.file
import host.pipe
import uuid
import snapshot show cache-snapshot extract-uuid
import supabase

import .client
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
  cmd := cli.Command "uploader"
      --help="""
        Administrative tool to upload CLI snapshots and Artemis service
        images to the Artemis server.

        Make sure to be authenticated against the Artemis server.
        """
      --options=[
        cli.OptionString "server"
            --help="The server to upload to.",
        cli.OptionString "snapshot-directory"
            --help="The directory to store the snapshot in.",
      ]

  cli-snapshot-cmd := cli.Command "cli-snapshot"
      --help="""
        Uploads the CLI snapshot to the Artemis server.

        After downloading it again with the downloader, allows to
        decode CLI system messages.

        Also copies the snapshot into the snapshot directory.
        """
      --rest=[
        cli.OptionString "snapshot"
            --help="The snapshot to upload."
            --type="file"
            --required,
      ]
      --run=:: upload-cli-snapshot config cache ui it
  cmd.add cli-snapshot-cmd

  service-cmd := cli.Command "service"
      --help="""
        Builds and uploads the Artemis service image.

        Downloads the SDK if necessary.

        The service is taken from this repository.

        There are three ways to specify which code should be built:
        1. If '--service-version' is specified, the code of the
          specified version is built, by cloning this repository
          into a temporary directory and checking out the specified
          version.
        2. If '--commit' is specified, the code of the specified commit
          is built, by cloning this repository into a temporary directory
          and checking out the specified commit. The full version string
          (as seen in the database) is then '<service-version>-<commit>'.
        3. If '--local' is specified, builds the service from the checked
          out code. If no service-version is provided, uses the one in the
          version.toit file.

        Note that there can only be one service/sdk version combination.
        Even if a version is uploaded to a specific organization-id, there
        can't be the same version for other organizations.

        The built image is then uploaded to the Artemis server.
        """
      --options=[
        cli.OptionString "sdk-version"
            --help="The version of the SDK to use."
            --required,
        cli.OptionString "service-version"
            --help="The version of the service to use.",
        cli.OptionEnum "chip-family" ["esp32"]
            --default="esp32"
            --help="The chip family to upload the service for.",
        cli.OptionString "commit"
            --help="The commit to build.",
        cli.Flag "local"
            --help="Build the service from the checked out code of the current repository.",
        cli.Option "organization-id"
            --help="The organization ID to upload the service to.",
        cli.Flag "force"
            --short-name="f"
            --help="Force the upload, even if the service already exists."
            --default=false,
        cli.Option "optimization-level"
            --short-name="O"
            --help="The optimization level to use."
            --default="2",
      ]
      --run=:: build-and-upload config cache ui it
  cmd.add service-cmd

  cmd.run args

service-path-in-repository root/string --chip-family/string -> string:
  return "$root/src/service/run/$(chip-family).toit"

build-and-upload config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  sdk-version := parsed["sdk-version"]
  service-version := parsed["service-version"]
  chip-family := parsed["chip-family"]
  commit := parsed["commit"]
  use-local := parsed["local"]
  snapshot-directory := parsed["snapshot-directory"]
  organization-id := parsed["organization-id"]
  force := parsed["force"]
  optimization-level := parsed["optimization-level"]

  git := Git --ui=ui
  // Get the SDK.
  sdk := get-sdk sdk-version --cache=cache
  root := git.current-repository-root

  with-tmp-directory: | tmp-dir/string |
    full-service-version := ?
    service-source-path := ?
    if use-local:
      // Build the service from the checked out code.
      // No caching is possible.
      // The full version string is then '<service-version>-<timestamp>',
      // where the timestamp is the time when the build was started.
      service-source-path = service-path-in-repository root --chip-family=chip-family

      // Since we are reusing an ID, we need to remove the cached version.
      full-service-version = service-version or ARTEMIS-VERSION
      cache-key := service-image-cache-key
          --sdk-version=sdk-version
          --service-version=full-service-version
          --artemis-config=get-artemis-config parsed config
      cache.remove cache-key
    else:
      ui.info "Cloning repository and checking out $(commit or service-version)."
      clone-dir := "$tmp-dir/artemis"
      git.init clone-dir --origin="file://$(url-encoding.encode root)"
      git.config --repository-root=clone-dir
          --key="advice.detachedHead"
          --value="false"
      git.fetch
          --checkout
          --depth=1
          --repository-root=clone-dir
          --ref=(commit or service-version)

      ui.info "Generating version.toit."
      exit-status := pipe.run-program ["make", "-C", clone-dir, "rebuild-cmake"]
      if exit-status != 0: throw "make failed with exit code $(pipe.exit-code exit-status)"

      ui.info "Downloading packages."
      sdk.download-packages clone-dir
      service-source-path = service-path-in-repository clone-dir --chip-family=chip-family
      if chip-family == "esp32" and not file.is-file service-source-path:
        // Older versions of Artemis used 'device.toit' as the entry point
        // for all ESP32 chips. We preserve compatibility with that by
        // mapping 'esp32' to 'device' if we can't find it under the new name.
        service-source-path = service-path-in-repository clone-dir --chip-family="device"

      full-service-version = service-version
      if commit: full-service-version += "-$commit"

    ar-file := "$tmp-dir/service.ar"
    ui.info "Creating snapshot."

    snapshot-path := "$tmp-dir/service.snapshot"
    sdk.compile-to-snapshot service-source-path
        --out=snapshot-path
        --flags=["-O$optimization-level"]

    create-image-archive snapshot-path --sdk=sdk --out=ar-file

    with-upload-client parsed config ui: | client/UploadClient |
      image-id := (uuid.uuid5 "artemis"
          "$Time.monotonic-us $sdk-version $full-service-version").stringify

      image-content := file.read-content ar-file
      snapshot-content := file.read-content snapshot-path
      client.upload
          --sdk-version=sdk-version
          --service-version=full-service-version
          --image-id=image-id
          --image-content=image-content
          --snapshot=snapshot-content
          --organization-id=organization-id
          --force=force

      cache-snapshot snapshot-content
          --output-directory=snapshot-directory

create-image-archive snapshot-path/string --sdk/Sdk --out/string:
  ar-stream := file.Stream.for-write out
  ar-writer := ar.ArWriter ar-stream

  ar-writer.add "artemis" """{ "magic": "🐅", "version": 1 }"""

  with-tmp-directory: | tmp-dir/string |
    [32, 64].do: | word-size |
      // Note that 'ar' file names can only be 15 characters long.
      image-name := "service-$(word-size).img"
      image-path := "$tmp-dir/$image-name"
      sdk.compile-snapshot-to-image
          --snapshot-path=snapshot-path
          --out=image-path
          --word-size=word-size

      ar-writer.add image-name (file.read-content image-path)

    ar-stream.close

upload-cli-snapshot config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  snapshot := parsed["snapshot"]
  snapshot-directory := parsed["snapshot-directory"]

  snapshot-content := file.read-content snapshot
  with-upload-client parsed config ui: | client/UploadClient |
    uuid := extract-uuid snapshot-content
    client.upload snapshot-content --snapshot-uuid=uuid

  cache-snapshot snapshot-content
      --output-directory=snapshot-directory
