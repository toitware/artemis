// Copyright (C) 2023 Toitware ApS.

import artemis.cli.pod show *
import expect show *
import .utils

main args:
  with-tmp-directory: | tmp-dir |
    id := random-uuid
    pod := Pod
        --id=id
        --chip="esp32"
        --name="name"
        --envelope="envelope".to-byte-array
        --tmp-directory=tmp-dir

    out := "$tmp-dir/$(id).pod"
    ui := TestUi
    pod.write out --ui=ui
    pod2 := Pod.parse out --ui=ui --tmp-directory=tmp-dir
    expect-equals id pod2.id
    expect-equals "name" pod2.name
    expect-equals "esp32" pod2.chip
    expect-equals "envelope".to-byte-array pod2.envelope
