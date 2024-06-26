// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import cli
import .src.snapshot

main args:
  cmd := cli.Command "snapshot-uuid"
      --help="""
        Extracts the UUID of the given snapshot.
        """
      --rest=[
        cli.Option "snapshot"
            --type="file"
            --required
            --help="The snapshot to get the UUID from.",
      ]
      --run=:: print (extract-uuid --path=it["snapshot"])
  cmd.run args
