// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import ar
import host.file
import cli
import uuid

main args:
  cmd := cli.Command "snapshot-uuid"
      --long_help="""
        Extracts the UUID of the given snapshot.
        """
      --rest=[
        cli.Option "snapshot"
            --type="file"
            --required
            --short_help="The snapshot to get the UUID from.",
      ]
      --run=:: extract_uuid it
  cmd.run args

extract_uuid parsed/cli.Parsed:
  snapshot := parsed["snapshot"]

  if not file.is_file snapshot:
    throw "Snapshot file not found: $snapshot"

  snapshot_bytes := file.read_content snapshot
  ar_reader := ar.ArReader.from_bytes snapshot_bytes
  ar_file := ar_reader.find "uuid"
  if not ar_file: throw "No uuid file in snapshot."
  uuid := (uuid.Uuid (ar_file.content)).stringify
  print uuid
