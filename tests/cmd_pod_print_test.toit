// Copyright (C) 2023 Toitware ApS.

import artemis.cli.utils show write_blob_to_file
import expect show *
import .utils

MINIMAL_SPEC_FILENAME ::= "minimal.json"
MINIMAL_SPEC ::= """
{
  "version": 1,
  "name": "test-pod-print",
  "sdk-version": "v0.0.0",
  "artemis-version": "v1.0.0"
}
"""

EXTENDED_SPEC ::= """
{
  "extends": [
    "$MINIMAL_SPEC_FILENAME"
  ],
  "max-offline": "1h"
}
"""

main args:
  with_test_cli --args=args: | test_cli/TestCli |
    run_test test_cli

run_test test_cli/TestCli:
  with_tmp_directory: | dir/string |
    test_cli.replacements[dir] = "TMP_DIR"

    minimal_spec_path := "$dir/$MINIMAL_SPEC_FILENAME"
    write_blob_to_file minimal_spec_path MINIMAL_SPEC

    extended_spec_path := "$dir/extended.json"
    write_blob_to_file extended_spec_path EXTENDED_SPEC

    test_cli.run_gold "AAA-print-spec"
        "Content of minimal spec"
        ["pod", "print", minimal_spec_path]

    test_cli.run_gold "BAA-print-spec-flat"
        "Content of minimal spec after flattening"
        ["pod", "print", "--flat", minimal_spec_path]

    test_cli.run_gold "CAA-print-spec"
        "Content of extended spec"
        ["pod", "print", extended_spec_path]

    test_cli.run_gold "DAA-print-spec-flat"
        "Content of extended spec after flattening"
        ["pod", "print", "--flat", extended_spec_path]
