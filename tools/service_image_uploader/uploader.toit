#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import cli
import encoding.url as url_encoding

// TODO(florian): these should come from the cli package.
import artemis.cli.config as cli
import artemis.cli.cache as cli
import artemis.cli.cache show service_image_cache_key
import artemis.cli.firmware show cache_snapshot
import artemis.cli.git show Git
import artemis.cli.sdk show *
import artemis.cli.ui as ui
import artemis.shared.version show ARTEMIS_VERSION
import host.file
import uuid
import supabase

import .client
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
  cmd := cli.Command "uploader"
      --long_help="""
        Administrative tool to upload CLI snapshots and Artemis service
        images to the Artemis server.

        Make sure to be authenticated against the Artemis server.
        """
      --options=[
        cli.OptionString "server"
            --short_help="The server to upload to.",
        cli.OptionString "snapshot-directory"
            --short_help="The directory to store the snapshot in.",
      ]

  cli_snapshot_cmd := cli.Command "cli-snapshot"
      --long_help="""
        Uploads the CLI snapshot to the Artemis server.

        After downloading it again with the downloader, allows to
        decode CLI system messages.

        Also copies the snapshot into the snapshot directory.
        """
      --rest=[
        cli.OptionString "snapshot"
            --short_help="The snapshot to upload."
            --type="file"
            --required,
      ]
      --run=:: upload_cli_snapshot config cache ui it
  cmd.add cli_snapshot_cmd

  service_cmd := cli.Command "service"
      --long_help="""
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

        The built image is then uploaded to the Artemis server.
        """
      --options=[
        cli.OptionString "sdk-version"
            --short_help="The version of the SDK to use."
            --required,
        cli.OptionString "service-version"
            --short_help="The version of the service to use.",
        cli.OptionString "commit"
            --short_help="The commit to build.",
        cli.Flag "local"
            --short_help="Build the service from the checked out code of the current repository.",
      ]
      --run=:: build_and_upload config cache ui it
  cmd.add service_cmd

  cmd.run args

SERVICE_PATH_IN_REPOSITORY ::= "src/service/run/device.toit"

build_and_upload config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  sdk_version := parsed["sdk-version"]
  service_version := parsed["service-version"]
  commit := parsed["commit"]
  use_local := parsed["local"]
  snapshot_directory := parsed["snapshot-directory"]

  git := Git
  // Get the SDK.
  sdk := get_sdk sdk_version --cache=cache
  root := git.current_repository_root

  with_tmp_directory: | tmp_dir/string |
    full_service_version := ?
    service_source_path := ?
    if use_local:
      // Build the service from the checked out code.
      // No caching is possible.
      // The full version string is then '<service-version>-<timestamp>',
      // where the timestamp is the time when the build was started.
      service_source_path = "$root/$SERVICE_PATH_IN_REPOSITORY"

      // Since we are reusing an ID, we need to remove the cached version.
      full_service_version = service_version or ARTEMIS_VERSION
      cache.remove (service_image_cache_key --sdk_version=sdk_version
          --service_version=full_service_version)
    else:
      ui.info "Cloning repository and checking out $(commit or service_version)."
      clone_dir := "$tmp_dir/artemis"
      git.init clone_dir --origin="file://$(url_encoding.encode root)"
      git.config --repository_root=clone_dir
          --key="advice.detachedHead"
          --value="false"
      git.fetch
          --checkout
          --depth=1
          --repository_root=clone_dir
          --ref=(commit or service_version)
      ui.info "Downloading packages."
      sdk.download_packages clone_dir
      service_source_path = "$clone_dir/$SERVICE_PATH_IN_REPOSITORY"

      full_service_version = service_version
      if commit: full_service_version += "-$commit"

    ar_file := "$tmp_dir/service.ar"
    ui.info "Creating snapshot."

    snapshot_path := "$tmp_dir/service.snapshot"
    sdk.compile_to_snapshot service_source_path --out=snapshot_path

    create_image_archive snapshot_path --sdk=sdk --out=ar_file

    with_upload_client parsed config ui: | client/UploadClient |
      image_id := (uuid.uuid5 "artemis"
          "$Time.monotonic_us $sdk_version $full_service_version").stringify

      image_content := file.read_content ar_file
      snapshot_content := file.read_content snapshot_path
      client.upload
          --sdk_version=sdk_version
          --service_version=full_service_version
          --image_id=image_id
          --image_content=image_content
          --snapshot=snapshot_content

      cache_snapshot snapshot_content
          --output_directory=snapshot_directory

create_image_archive snapshot_path/string --sdk/Sdk --out/string:
  ar_stream := file.Stream.for_write out
  ar_writer := ar.ArWriter ar_stream

  ar_writer.add "artemis" """{ "magic": "🐅", "version": 1 }"""

  with_tmp_directory: | tmp_dir/string |
    [32, 64].do: | word_size |
      // Note that 'ar' file names can only be 15 characters long.
      image_name := "service-$(word_size).img"
      image_path := "$tmp_dir/$image_name"
      sdk.compile_snapshot_to_image
          --snapshot_path=snapshot_path
          --out=image_path
          --word_size=word_size

      ar_writer.add image_name (file.read_content image_path)

    ar_stream.close

upload_cli_snapshot config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  snapshot := parsed["snapshot"]
  snapshot_directory := parsed["snapshot-directory"]

  snapshot_content := file.read_content snapshot
  with_upload_client parsed config ui: | client/UploadClient |
    uuid := extract_snapshot_uuid_ snapshot_content
    client.upload snapshot_content --snapshot_uuid=uuid

  cache_snapshot snapshot_content
      --output_directory=snapshot_directory
