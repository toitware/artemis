#!/usr/bin/env toit.run

// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate-roots
import cli show *
import encoding.url as url-encoding

import artemis.cli.cache show cache-key-service-image
import artemis.cli.git show Git
import artemis.cli.sdk show *
import artemis.shared.version show ARTEMIS-VERSION
import host.file
import host.pipe
import uuid
import snapshot show cache-snapshot extract-uuid
import supabase

import .client
import .utils

CHIP-FAMILIES ::= [
  "esp32",
  "host",
]

main args/List:
  // Use the same application name as the
  // This way we get the same config and cache.
  // The config gives as the server configurations and oauth tokens.
  // The cache the SDKs.
  cli := Cli "artemis"
  main args --cli=cli

main args/List --cli/Cli?:
  certificate-roots.install-all-trusted-roots

  cmd := Command "uploader"
      --help="""
        Administrative tool to upload CLI snapshots and Artemis service
        images to the Artemis server.

        Make sure to be authenticated against the Artemis server.
        """
      --options=[
        Option "server"
            --help="The server to upload to.",
        Option "snapshot-directory"
            --help="The directory to store the snapshot in.",
      ]

  cli-snapshot-cmd := Command "cli-snapshot"
      --help="""
        Uploads the CLI snapshot to the Artemis server.

        After downloading it again with the downloader, allows to
        decode CLI system messages.

        Also copies the snapshot into the snapshot directory.
        """
      --rest=[
        Option "snapshot"
            --help="The snapshot to upload."
            --type="file"
            --required,
      ]
      --run=:: upload-cli-snapshot it
  cmd.add cli-snapshot-cmd

  service-cmd := Command "service"
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
        Option "sdk-version"
            --help="The version of the SDK to use."
            --required,
        Option "service-version"
            --help="The version of the service to use.",
        Option "commit"
            --help="The commit to build.",
        Flag "local"
            --help="Build the service from the checked out code of the current repository.",
        Option "organization-id"
            --help="The organization ID to upload the service to.",
        Flag "force"
            --short-name="f"
            --help="Force the upload, even if the service already exists."
            --default=false,
        Option "optimization-level"
            --short-name="O"
            --help="The optimization level to use."
            --default="2",
      ]
      --examples=[
        Example "Upload the checked out code as version v0.5.5.pre.1+fix.foo to organization 3ea5b632-5739-4f40-8446-2fc102a5b338:"
            --arguments="--sdk-version=v2.0.0-alpha.139 --service-version=v0.5.5.pre.1+fix.foo --organization-id=3ea5b632-5739-4f40-8446-2fc102a5b338",
        Example "Upload the commit faea5684479957e48b945f7fdf4cbc70c0053225 as version v0.5.5.pre.2+updated to organization 3ea5b632-5739-4f40-8446-2fc102a5b338:"
            --arguments="--sdk-version=v2.0.0-alpha.139 --service-version=v0.5.5.pre.2+updated --commit=faea5684479957e48b945f7fdf4cbc70c0053225 --organization-id=3ea5b632-5739-4f40-8446-2fc102a5b338",
        Example "Upload the build v2.0.0-alpha.140/v0.5.5 to the server for everyone:"
            --arguments="--sdk-version=v2.0.0-alpha.140 --service-version=v0.5.5"
      ]
      --run=:: build-and-upload it
  cmd.add service-cmd

  cmd.run args --cli=cli

service-path-in-repository root/string --chip-family/string -> string:
  return "$root/src/service/run/$(chip-family).toit"

build-and-upload invocation/Invocation:
  params := invocation.parameters
  cli := invocation.cli
  ui := cli.ui

  sdk-version := params["sdk-version"]
  service-version := params["service-version"]
  commit := params["commit"]
  use-local := params["local"]
  snapshot-directory := params["snapshot-directory"]
  organization-id := params["organization-id"]
  force := params["force"]
  optimization-level := params["optimization-level"]

  git := Git --cli=cli
  // Get the SDK.
  sdk := get-sdk sdk-version --cli=cli
  root := git.current-repository-root

  with-tmp-directory: | tmp-dir/string |
    full-service-version/string := ?
    repo-path/string := ?

    if use-local:
      // Build the service from the checked out code.
      // No caching is possible.
      // The full version string is then '<service-version>-<timestamp>',
      // where the timestamp is the time when the build was started.

      repo-path = root
      full-service-version = service-version or ARTEMIS-VERSION
    else:
      ui.emit --info "Cloning repository and checking out $(commit or service-version)."
      repo-path = "$tmp-dir/artemis"
      git.init repo-path --origin="file://$(url-encoding.encode root)"
      git.config --repository-root=repo-path
          --key="advice.detachedHead"
          --value="false"
      git.fetch
          --checkout
          --depth=1
          --repository-root=repo-path
          --ref=(commit or service-version)

      ui.emit --info "Downloading packages."
      sdk.pkg-install --project-root=repo-path

      full-service-version = service-version
      if commit: full-service-version += "-$commit"

    artemis-config := get-artemis-config --cli=cli
    // Since we are potentially reusing an ID, we need to remove the cached versions.
    CHIP-FAMILIES.do: | chip-family |
      [32, 64].do: | word-size |
        cache-key := cache-key-service-image
            --sdk-version=sdk-version
            --service-version=full-service-version
            --artemis-config=artemis-config
            --chip-family=chip-family
            --word-size=word-size
        cli.cache.remove cache-key

    service-source-paths := CHIP-FAMILIES.map: | chip-family/string |
      service-path-in-repository repo-path --chip-family=chip-family

    ui.emit --info "Generating version.toit."
    exit-status := pipe.run-program
        --environment={"ARTEMIS_GIT_VERSION": full-service-version}
        ["make", "-C", repo-path, "rebuild-cmake"]
    if exit-status != 0: throw "make failed with exit code $(pipe.exit-code exit-status)"

    ar-file := "$tmp-dir/service.ar"
    ui.emit --info "Creating snapshot."

    snapshot-paths := {:}
    CHIP-FAMILIES.do: | chip-family/string |
      service-source-path := service-path-in-repository repo-path --chip-family=chip-family
      if not file.is-file service-source-path:
        throw "Service source file '$service-source-path' does not exist."
      snapshot-path := "$tmp-dir/service-$(chip-family).snapshot"
      sdk.compile-to-snapshot service-source-path
          --out=snapshot-path
          --flags=["-O$optimization-level"]
      snapshot-paths[chip-family] = snapshot-path

    create-image-archive snapshot-paths --sdk=sdk --out=ar-file

    with-upload-client invocation: | client/UploadClient |
      image-id := (uuid.uuid5 "artemis"
          "$Time.monotonic-us $sdk-version $full-service-version").stringify

      image-content := file.read-content ar-file
      snapshots := snapshot-paths.map: | _ snapshot-path | file.read-content snapshot-path
      client.upload
          --sdk-version=sdk-version
          --service-version=full-service-version
          --image-id=image-id
          --image-content=image-content
          --snapshots=snapshots
          --organization-id=organization-id
          --force=force

      snapshots.do: | _ snapshot-content/ByteArray |
        cache-snapshot snapshot-content
            --output-directory=snapshot-directory

create-image-archive snapshot-paths/Map --sdk/Sdk --out/string:
  ar-stream := file.Stream.for-write out
  ar-writer := ar.ArWriter ar-stream

  ar-writer.add "artemis" """{ "magic": "�", "version": 2 }"""

  with-tmp-directory: | tmp-dir/string |
    snapshot-paths.do: | chip-family/string snapshot-path/string |
      [32, 64].do: | word-size |
        // Note that 'ar' file names can only be 15 characters long.
        image-name := "$(chip-family)-$(word-size).img"
        image-path := "$tmp-dir/$image-name"
        sdk.compile-snapshot-to-image
            --snapshot-path=snapshot-path
            --out=image-path
            --word-sizes=[word-size]

        ar-writer.add image-name (file.read-content image-path)
        if chip-family == "esp32":
          // Add the same image again with the deprecated name.
          // TODO(florian): remove deprecated image name without chip-family.
          ar-writer.add "service-$(word-size).img" (file.read-content image-path)

  ar-stream.close

upload-cli-snapshot invocation/Invocation:
  snapshot := invocation["snapshot"]
  snapshot-directory := invocation["snapshot-directory"]

  snapshot-content := file.read-content snapshot
  with-upload-client invocation: | client/UploadClient |
    uuid := extract-uuid snapshot-content
    client.upload snapshot-content --snapshot-uuid=uuid

  cache-snapshot snapshot-content
      --output-directory=snapshot-directory
