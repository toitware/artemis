#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import cli
// TODO(florian): these should come from the cli package.
import artemis.cli.config as cli
import artemis.cli.cache as cli
import artemis.cli.ui as ui
import host.file
import uuid
import supabase

import .git
import .sdk
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
        Builds and uploads the Artemis service image.

        Downloads the SDK if necessary.

        The service is taken from this repository.

        There are three ways to specify which code should be built:
        1. If just '--service-version' is specified, the code of the
          specified version is built, by cloning this repository
          into a temporary directory and checking out the specified
          version.
        2. If '--commit' is specified, the code of the specified commit
          is built, by cloning this repository into a temporary directory
          and checking out the specified commit. The full version string
          (as seen in the database) is then '<service-version>-<commit>'.
        3. If '--local' is specified, builds the service from the checked
          out code. The full version string is then '<service-version>-<timestamp>',
          where the timestamp is the time when the build was started.

        The built image is then uploaded to the Artemis server.
        """
      --options=[
        cli.OptionString "sdk-version"
            --short_help="The version of the SDK to use."
            --required,
        cli.OptionString "service-version"
            --short_help="The version of the service to use."
            --required,
        cli.OptionString "commit"
            --short_help="The commit to build.",
        cli.OptionString "server"
            --short_help="The server to upload to.",
        cli.Flag "local"
            --short_help="Build the service from the checked out code of the current repository.",
      ]
      --run=:: build_and_upload config cache ui it
  cmd.run args

SERVICE_PATH_IN_REPOSITORY ::= "src/service/run/device.toit"

build_and_upload config/cli.Config cache/cli.Cache ui/ui.Ui parsed/cli.Parsed:
  sdk_version := parsed["sdk-version"]
  service_version := parsed["service-version"]
  commit := parsed["commit"]
  use_local := parsed["local"]

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

      timestamp := Time.now.stringify
      full_service_version = "$service_version-$timestamp"
    else:
      ui.info "Cloning repository and checking out $(commit or service_version)."
      clone_dir := "$tmp_dir/artemis"
      git.clone root --out=clone_dir --ref=(commit or service_version)
      ui.info "Downloading packages."
      sdk.download_packages clone_dir
      service_source_path = "$clone_dir/$SERVICE_PATH_IN_REPOSITORY"

      full_service_version = service_version
      if commit: full_service_version += "-$commit"

    ar_file := "$tmp_dir/service.ar"
    ui.info "Creating image archive."
    create_image_archive service_source_path --sdk=sdk --out=ar_file

    with_supabase_client parsed config: | client/supabase.Client |
      ui.info "Uploading image archive."

      // TODO(florian): share constants with the CLI.
      sdk_ids := client.rest.select "sdks" --filters=[
        "version=eq.$sdk_version",
      ]
      sdk_id := ?
      if not sdk_ids.is_empty:
        sdk_id = sdk_ids[0]["id"]
      else:
        inserted := client.rest.insert "sdks" {
          "version": sdk_version,
        }
        sdk_id = inserted["id"]

      service_ids := client.rest.select "artemis_services" --filters=[
        "version=eq.$full_service_version",
      ]
      service_id := ?
      if not service_ids.is_empty:
        service_id = service_ids[0]["id"]
      else:
        inserted := client.rest.insert "artemis_services" {
          "version": full_service_version,
        }
        service_id = inserted["id"]

      image_id := (uuid.uuid5 "artemis"
          "$Time.monotonic_us $sdk_version $full_service_version").stringify

      client.rest.insert "service_images" {
        "sdk_id": sdk_id,
        "service_id": service_id,
        "image": image_id,
      }

      client.storage.upload
          --path="service-images/$image_id"
          --content=(file.read_content ar_file)

      ui.info "Successfully uploaded $full_service_version into service-images/$image_id."

create_image_archive service_source_path/string --sdk/Sdk --out/string:
  ar_stream := file.Stream.for_write out
  ar_writer := ar.ArWriter ar_stream

  with_tmp_directory: | tmp_dir/string |
    snapshot_path := "$tmp_dir/service.snapshot"
    sdk.compile_to_snapshot service_source_path --out=snapshot_path

    [32, 64].do: | bits |
      // Note that 'ar' file names can only be 15 characters long.
      image_name := "service-$(bits).img"
      image_path := "$tmp_dir/$image_name"
      sdk.compile_snapshot_to_image
          --snapshot_path=snapshot_path
          --out=image_path
          --bits=bits

      ar_writer.add image_name (file.read_content image_path)

    ar_stream.close
