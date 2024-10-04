// Copyright (C) 2023 Toitware ApS.

import artemis.cli.pod show *
import expect show *
import .utils

main args:
  with-tmp-directory: | tmp-dir |
    id := random-uuid
    pod := Pod
        --id=id
        --name="name"
        --envelope="envelope".to-byte-array
        --tmp-directory=tmp-dir

    out := "$tmp-dir/$(id).pod"
    cli := TestCli
    pod.write out --cli=cli
    pod2 := Pod.parse out --cli=cli --tmp-directory=tmp-dir
    expect-equals id pod2.id
    expect-equals "name" pod2.name
    expect-equals "envelope".to-byte-array pod2.envelope
