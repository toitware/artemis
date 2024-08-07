// Copyright (C) 2023 Toitware ApS.

import artemis.cli.utils show write-blob-to-file write-yaml-to-file
import expect show *
import .utils

MINIMAL-SPEC-FILENAME ::= "minimal.yaml"
MINIMAL-SPEC ::= {
  "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
  "name": "test-pod-print",
  "sdk-version": "v0.0.0",
  "artemis-version": "v1.0.0",
  "firmware-envelope": "esp32",
}

EXTENDED-SPEC ::= {
  "extends": [
    "$MINIMAL-SPEC-FILENAME",
  ],
  "max-offline": "1h",
}

main args:
  with-tester --args=args: | tester/Tester |
    run-test tester

run-test tester/Tester:
  with-tmp-directory: | dir/string |
    tester.replacements[dir] = "TMP_DIR"

    minimal-spec-path := "$dir/$MINIMAL-SPEC-FILENAME"
    write-yaml-to-file minimal-spec-path MINIMAL-SPEC

    extended-spec-path := "$dir/extended.yaml"
    write-yaml-to-file extended-spec-path EXTENDED-SPEC

    tester.run-gold "AAA-print-spec"
        "Content of minimal spec"
        ["pod", "print", minimal-spec-path]

    tester.run-gold "BAA-print-spec-flat"
        "Content of minimal spec after flattening"
        ["pod", "print", "--flat", minimal-spec-path]

    tester.run-gold "CAA-print-spec"
        "Content of extended spec"
        ["pod", "print", extended-spec-path]

    tester.run-gold "DAA-print-spec-flat"
        "Content of extended spec after flattening"
        ["pod", "print", "--flat", extended-spec-path]
