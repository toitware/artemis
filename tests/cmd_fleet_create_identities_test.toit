// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import encoding.json
import host.directory
import host.file
import expect show *
import .utils

main args:
  with_fleet --count=0 --args=args: | test_cli/TestCli _ fleet_dir/string |
    run_test test_cli fleet_dir

run_test test_cli/TestCli fleet_dir/string:
  with_tmp_directory: | tmp_dir |
    test_cli.run [
      "auth", "login",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    test_cli.run [
      "auth", "login",
      "--broker",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    count := 3
    test_cli.run [
      "fleet",
      "create-identities",
      "--output-directory", tmp_dir,
      "$count",
    ]
    check_and_remove_identity_files fleet_dir tmp_dir count

check_and_remove_identity_files fleet_dir tmp_dir count:
  devices := json.decode (file.read_content "$fleet_dir/devices.json")
  expect_equals count devices.size
  stream := directory.DirectoryStream tmp_dir
  count.repeat:
    identity_file := stream.next
    expect (identity_file.ends_with "identity")
    without_extension := identity_file[..identity_file.size - 9]
    expect (devices.contains without_extension)
    file.delete "$tmp_dir/$identity_file"
  expect_null stream.next
  // Reset the devices.json.
  devices_stream := file.Stream.for_write "$fleet_dir/devices.json"
  devices_stream.write "{}"
  devices_stream.close
