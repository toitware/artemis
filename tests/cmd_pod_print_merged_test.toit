// Copyright (C) 2023 Toitware ApS.

import artemis.cli.utils show write_blob_to_file
import expect show *
import .utils

MINIMAL_SPEC ::= """
{
  "version": 1,
  "name": "test-pod-print",
  "sdk-version": "v0.0.0",
  "artemis-version": "v1.0.0"
}
"""

main args:
  with_test_cli --args=args: | test_cli/TestCli |
    run_test test_cli

run_test test_cli/TestCli:
  with_tmp_directory: | dir/string |
    spec_path := "$dir/spec.json"
    write_blob_to_file spec_path MINIMAL_SPEC
    print "Wrote minimal spec to $spec_path"

    test_cli.run_gold "AAA-print-merged-spec"
        "Content of minimal spec"
        ["pod", "print-merged", spec_path]
