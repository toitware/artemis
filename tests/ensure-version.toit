// Copyright (C) 2024 Toitware ApS. All rights reserved.

import artemis.shared.version show ARTEMIS-VERSION
import host.file
import host.pipe

main args:
  repo-path := args[0]
  // The ARTEMIS-VERSION is the currently configured version of the Artemis tool.
  test-version := "$(ARTEMIS-VERSION.trim --right "-TEST")-TEST"
  if test-version != ARTEMIS-VERSION:
    // Update the version.toit file.
    exit-status := pipe.run-program
        --environment={"ARTEMIS_GIT_VERSION": test-version}
        ["make", "-C", repo-path, "rebuild-cmake"]
    if exit-status != 0: throw "make failed with exit code $(pipe.exit-code exit-status)"
