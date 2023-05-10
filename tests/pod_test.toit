// Copyright (C) 2023 Toitware ApS.

import artemis.cli.pod show *
import expect show *
import .utils

main args:
  with_tmp_directory: | tmp_dir |
    id := random_uuid
    pod := Pod
        --id=id
        --name="name"
        --envelope="envelope".to_byte_array
        --tmp_directory=tmp_dir

    out := "$tmp_dir/$(id).pod"
    ui := TestUi
    pod.write out --ui=ui
    pod2 := Pod.parse out --ui=ui --tmp_directory=tmp_dir
    expect_equals id pod2.id
    expect_equals "name" pod2.name
    expect_equals "envelope".to_byte_array pod2.envelope
