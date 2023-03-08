// Copyright (C) 2022 Toitware ApS.

import expect show *
import host.directory
import host.file

import .utils
import ..tools.service_image_uploader.uploader as uploader
import ..tools.service_image_uploader.downloader as downloader
import artemis.shared.version show ARTEMIS_VERSION
import artemis.cli.git show Git

main args:
  // Start a TestCli, since that will set up everything the way we want.
  with_test_cli --args=args --artemis_type="supabase": run_test it

// The SDK version that is used for this test.
// It's safe to update the version to a newer version.
SDK_VERSION ::= "v2.0.0-alpha.62"

// Just a commit that exists on main.
// It's safe to update the commit to a newer version.
TEST_COMMIT ::= "58f2d290269fe497945b3faa921803c8ef56de8d"

run_main_test test_cli/TestCli tmp_dir/string service_version/string [block]:
  block.call
  // Check that the service is available.
  available_sdks := test_cli.run [
    "sdk", "list", "--sdk-version", SDK_VERSION, "--service-version", service_version
  ]
  expect (available_sdks.contains service_version)

  // Check that the snapshot was written into the snapshot directory.
  files_iterator := directory.DirectoryStream tmp_dir
  files := []
  while file_name := files_iterator.next: files.add file_name
  files_iterator.close
  expect_equals 1 files.size

  // Delete the files.
  file.delete "$tmp_dir/$files[0]"

  // Check that the file was deleted.
  files_iterator = directory.DirectoryStream tmp_dir
  files = []
  while file_name := files_iterator.next: files.add file_name
  files_iterator.close
  expect_equals 0 files.size

run_test test_cli/TestCli:
  with_tmp_directory: | tmp_dir/string |
    git := Git

    // Login using the CLI login.
    // The uploader reuses the same credentials.
    test_cli.run [
      "auth", "artemis", "login",
      "--email", ADMIN_EMAIL,
      "--password", ADMIN_PASSWORD
    ]

    service_version := "v0.0.$(random)-TEST"

    // The test-server could have already been used.
    // We want to avoid duplicates, so we create a new version number.
    // This means that we create a new tag every time we run this test.
    // We try to remove it afterwards, but if the program is interrupted
    // we might leave a tag behind. In that case it's safe to delete
    // the tag manually.
    git.tag --name=service_version --commit=TEST_COMMIT
    try:
      run_main_test test_cli tmp_dir service_version:
        uploader.main
            --config=test_cli.config
            --cache=test_cli.cache
            --ui=TestUi
            [
              "service",
              "--sdk-version", SDK_VERSION,
              "--service-version", service_version,
              "--snapshot-directory", tmp_dir,
            ]

      // Try with a specific commit.
      commit_version := "$service_version-$(TEST_COMMIT)"
      run_main_test test_cli tmp_dir commit_version:
        uploader.main
            --config=test_cli.config
            --cache=test_cli.cache
            --ui=TestUi
            [
              "service",
              "--sdk-version", SDK_VERSION,
              "--service-version", service_version,
              "--commit", TEST_COMMIT,
              "--snapshot-directory", tmp_dir,
            ]

      // Try with local.

      // With service version.
      local_version := "$service_version-$Time.now"
      run_main_test test_cli tmp_dir local_version:
        uploader.main
            --config=test_cli.config
            --cache=test_cli.cache
            --ui=TestUi
            [
              "service",
              "--sdk-version", SDK_VERSION,
              "--service-version", local_version,
              "--local",
              "--snapshot-directory", tmp_dir,
            ]

      // Without service version.
      run_main_test test_cli tmp_dir ARTEMIS_VERSION:
        uploader.main
            --config=test_cli.config
            --cache=test_cli.cache
            --ui=TestUi
            [
              "service",
              "--sdk-version", SDK_VERSION,
              "--local",
              "--snapshot-directory", tmp_dir,
            ]

    finally:
      git.tag --delete --name=service_version

    // Download a service.
    downloader.main
        --config=test_cli.config
        --cache=test_cli.cache
        --ui=TestUi
        [
          "--sdk-version", SDK_VERSION,
          "--service-version", service_version,
          "--output-directory", tmp_dir,
        ]

    // Check that the file was downloaded.
    files_iterator := directory.DirectoryStream tmp_dir
    files := []
    while file_name := files_iterator.next: files.add file_name
    files_iterator.close
    expect_equals 1 files.size
