// Copyright (C) 2023 Toitware ApS.

import artemis.cli.utils show write-blob-to-file
import expect show *
import .utils

MINIMAL-SPEC-FILENAME ::= "minimal.json"
MINIMAL-SPEC ::= """
{
  "version": 1,
  "name": "test-pod-print",
  "sdk-version": "v0.0.0",
  "artemis-version": "v1.0.0"
}
"""

EXTENDED-SPEC ::= """
{
  "extends": [
    "$MINIMAL-SPEC-FILENAME"
  ],
  "max-offline": "1h"
}
"""

main args:
  with-test-cli --args=args: | test-cli/TestCli |
    run-test test-cli

run-test test-cli/TestCli:
  with-tmp-directory: | dir/string |
    test-cli.replacements[dir] = "TMP_DIR"

    minimal-spec-path := "$dir/$MINIMAL-SPEC-FILENAME"
    write-blob-to-file minimal-spec-path MINIMAL-SPEC

    extended-spec-path := "$dir/extended.json"
    write-blob-to-file extended-spec-path EXTENDED-SPEC

    test-cli.run-gold "AAA-print-spec"
        "Content of minimal spec"
        ["pod", "print", minimal-spec-path]

    test-cli.run-gold "BAA-print-spec-flat"
        "Content of minimal spec after flattening"
        ["pod", "print", "--flat", minimal-spec-path]

    test-cli.run-gold "CAA-print-spec"
        "Content of extended spec"
        ["pod", "print", extended-spec-path]

    test-cli.run-gold "DAA-print-spec-flat"
        "Content of extended spec after flattening"
        ["pod", "print", "--flat", extended-spec-path]
