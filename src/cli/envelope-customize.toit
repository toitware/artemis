// Copyright (C) 2026 Toit contributors.

import cli show Cli
import crypto.sha256
import host.file
import host.os
import uuid show Uuid

import .container-description show build-container-description
import .firmware show
    cache-snapshots
    get-artemis-container
    get-envelope
import .pod-specification show
    BootTrigger
    ConnectionInfo
    Container
    PodSpecification
    Trigger
import .program show extract-id-from-snapshot
import .sdk show Sdk get-sdk
import .server-config show ServerConfig server-config-to-service-json
import .utils show copy-file is-dev-setup with-tmp-directory
import ..shared.version show ARTEMIS-VERSION-MAJOR ARTEMIS-VERSION-MINOR

/**
Customizes a generic Toit envelope with the given $specification.

Reads the pod spec, fetches the matching SDK and Artemis service
  container, embeds the configured app containers and the broker config,
  and writes the result to $output-path. The image is then ready to be
  flashed together with an identity file.

Independent of any broker connection: $server-config supplies the
  brokers and certificates that the device needs at runtime.
*/
customize-envelope -> none
    --organization-id/Uuid
    --specification/PodSpecification
    --recovery-urls/List
    --output-path/string
    --server-config/ServerConfig
    --cli/Cli:
  service-version := specification.artemis-version
  sdk-version := specification.sdk-version

  envelope-path := get-envelope
      --specification=specification
      --cli=cli

  // Extract the sdk version from the envelope.
  envelope := file.read-contents envelope-path
  envelope-sdk-version := Sdk.get-sdk-version-from --envelope=envelope
  envelope-chip-family := Sdk.get-chip-family-from --envelope=envelope
  if sdk-version:
    if sdk-version != envelope-sdk-version:
      if not (is-dev-setup and os.env.get "DEV_TOIT_REPO_PATH"):
        cli.ui.abort "The envelope uses SDK version $envelope-sdk-version, but $sdk-version was requested."
  else:
    sdk-version = envelope-sdk-version

  sdk := get-sdk sdk-version --cli=cli

  copy-file --source=envelope-path --target=output-path

  device-config := {
    "sdk-version": sdk-version,
  }

  // Add the max-offline setting if is non-zero. The device service
  // handles the absence of the max-offline setting differently, so
  // we cannot just add zero seconds to the config. This matches what
  // we do in $config_set_max_offline.
  max-offline-seconds := specification.max-offline-seconds
  if max-offline-seconds > 0: device-config["max-offline"] = max-offline-seconds

  if specification.connections.is-empty and not has-implicit-network_ envelope-chip-family:
    cli.ui.emit --warning "No network connections configured."
  connections := specification.connections.map: | connection/ConnectionInfo |
    connection.to-json
  device-config["connections"] = connections

  // Create the assets for the device service.
  // TODO(florian): share this code with the identity creation code.
  der-certificates := {:}
  broker-json := server-config-to-service-json server-config der-certificates

  with-tmp-directory: | tmp-dir |
    // Store the containers in the envelope.
    specification.containers.do: | name/string container/Container |
      snapshot-path := "$tmp-dir/$(name).snapshot"
      container.build-snapshot
          --relative-to=specification.relative-to
          --sdk=sdk
          --output-path=snapshot-path
          --cli=cli

      // Build the assets from the defines (if any).
      assets-path/string? := null
      if container.defines:
        assets-path = "$tmp-dir/$(name).assets"
        assets := {
          "artemis.defines": {
            "format": "tison",
            "json": container.defines
          }
        }
        sdk.assets-create --output-path=assets-path assets

      sdk.firmware-add-container name
          --envelope=output-path
          --assets=assets-path
          --program-path=snapshot-path
          --trigger="none"

      // TODO(kasper): Avoid computing the image id here. We should
      // be able to get it from the firmware tool.
      sha := sha256.Sha256
      snapshot-uuid-string := extract-id-from-snapshot snapshot-path
      sha.add (Uuid.parse snapshot-uuid-string).to-byte-array
      if assets-path:
        sha.add (file.read-contents assets-path)
      id := Uuid sha.get[..Uuid.SIZE]

      triggers := container.triggers
      if not container.is-critical and not triggers:
        // Non-critical containers default to having a boot trigger.
        triggers = [BootTrigger]
      apps := device-config.get "apps" --init=:{:}
      apps[name] = build-container-description
          --id=id
          --arguments=container.arguments
          --background=container.is-background
          --critical=container.is-critical
          --runlevel=container.runlevel
          --triggers=triggers
      cli.ui.emit --info "Added container '$name' to envelope."

    artemis-assets := {
      // TODO(florian): share the keys of the assets with the Artemis service.
      "broker": {
        "format": "tison",
        "json": broker-json,
      },
      "artemis.broker": {
        "format": "tison",
        "json": broker-json,
      },
    }
    der-certificates.do: | name/string value/ByteArray |
      // The 'server_config_to_service_json' function puts the certificates
      // into their own namespace.
      assert: name.starts-with "certificate-"
      artemis-assets[name] = {
        "format": "binary",
        "blob": value,
      }

    artemis-assets["device-config"] = {
      "format": "ubjson",
      "json": device-config,
    }

    artemis-assets["recovery-urls"] = {
      "format": "tison",
      "json": recovery-urls,
    }

    artemis-assets-path := "$tmp-dir/artemis.assets"
    sdk.assets-create --output-path=artemis-assets-path artemis-assets

    // Build the Artemis service image.
    artemis-container := get-artemis-container service-version --chip-family=envelope-chip-family --cli=cli
    artemis-snapshot-path := "$tmp-dir/artemis.snapshot"
    create-version-file := :: | repo-path/string |
      // TODO(florian): share this code with the identity creation code.
      version-path := "$repo-path/src/shared/version.toit"
      if not file.is-file version-path:
        // We already have the version from the container.
        // We still need to extract a major and minor version.
        artemis-version := artemis-container.git-ref
        artemis-major/int := ?
        artemis-minor/int := ?
        if not artemis-version:
          cli.ui.abort "Local Artemis checkouts must have a version.toit file."
        parts := (artemis-version.trim --left "v").split "."
        if parts.size < 2:
          // Probably just a commit hash or full ref.
          // This should only happen during development. Use our version instead.
          artemis-major = ARTEMIS-VERSION-MAJOR
          artemis-minor = ARTEMIS-VERSION-MINOR
        else:
          had-error := false
          artemis-major = int.parse parts[0] --on-error=:
            had-error = true
            0
          artemis-minor = int.parse parts[1] --on-error=:
            had-error = true
            0
          if had-error:
            artemis-major = ARTEMIS-VERSION-MAJOR
            artemis-minor = ARTEMIS-VERSION-MINOR
        version-contents := """
          // This file is generated by the Toit SDK.
          // Do not edit.
          ARTEMIS-VERSION ::= "$artemis-version"
          ARTEMIS-VERSION-MAJOR ::= $artemis-major
          ARTEMIS-VERSION-MINOR ::= $artemis-minor
          """
        file.write-contents --path=version-path version-contents
    artemis-container.build-snapshot
        --pre-compilation-hook=create-version-file
        --relative-to=specification.relative-to
        --sdk=sdk
        --output-path=artemis-snapshot-path
        --cli=cli
    cli.ui.emit --info "Added Artemis service container to envelope."

    sdk.firmware-add-container "artemis"
        --envelope=output-path
        --assets=artemis-assets-path
        --program-path=artemis-snapshot-path
        --trigger="boot"
        --critical

  // For convenience save all snapshots in the user's cache.
  cache-snapshots --envelope-path=output-path --cli=cli

has-implicit-network_ chip-family/string -> bool:
  return chip-family == "host"
