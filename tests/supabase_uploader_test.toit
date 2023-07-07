// Copyright (C) 2022 Toitware ApS.

import expect show *
import host.directory
import host.file
import artemis.cli.ui show ConsoleUi

import .utils
import .artemis_server
import ..tools.service_image_uploader.uploader as uploader
import ..tools.service_image_uploader.downloader as downloader
import artemis.shared.version show ARTEMIS_VERSION
import artemis.cli.git show Git
import supabase

main args:
  // Start a TestCli, since that will set up everything the way we want.
  with_test_cli --args=args --artemis_type="supabase":
    run_test it

// Just a commit that exists on main.
// It's safe to update the commit to a newer version.
TEST_COMMIT ::= "58f2d290269fe497945b3faa921803c8ef56de8d"

run_main_test
    test_cli/TestCli
    tmp_dir/string
    service_version/string
    --keep_service/bool=false
    [block]:
  block.call
  // Check that the service is available.
  available_sdks := test_cli.run [
    "sdk", "list", "--sdk-version", test_cli.sdk_version, "--service-version", service_version
  ]
  if not available_sdks.contains service_version:
    print "Available sdks: $available_sdks"
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

  if not keep_service:
    delete_service_version test_cli service_version

delete_service_version test_cli/TestCli service_version/string:
  supabase_backdoor := test_cli.artemis.backdoor as SupabaseBackdoor
  supabase_backdoor.with_backdoor_client_: | client/supabase.Client |
    client.rest.delete "artemis_services" --filters=[
      "version=eq.$service_version",
    ]

run_test test_cli/TestCli:
  sdk_version := test_cli.sdk_version
  with_tmp_directory: | tmp_dir/string |
    ui := TestUi --no-quiet
    git := Git --ui=ui

    // Login using the CLI login.
    // The uploader reuses the same credentials.
    test_cli.run [
      "auth", "login",
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
      // We keep the service for the next test.
      run_main_test test_cli tmp_dir service_version --keep_service:
        uploader.main
            --config=test_cli.config
            --cache=test_cli.cache
            --ui=ui
            [
              "service",
              "--sdk-version", sdk_version,
              "--service-version", service_version,
              "--snapshot-directory", tmp_dir,
            ]

      // Debug information to analyze flaky tests.
      supabase_backdoor := test_cli.artemis.backdoor as SupabaseBackdoor
      supabase_backdoor.with_backdoor_client_: | client/supabase.Client |
        service_images := client.rest.select "service_images"
        print "Service images before 2nd attempt: $service_images"

      // Without force we can't upload the same version again.
      exception := catch:
        uploader.main
            --config=test_cli.config
            --cache=test_cli.cache
            --ui=ui
            [
              "service",
              "--sdk-version", sdk_version,
              "--service-version", service_version,
              "--snapshot-directory", tmp_dir,
            ]
      if exception is not TestExit:
        // Debug information to analyze flaky tests.
        supabase_backdoor.with_backdoor_client_: | client/supabase.Client |
          service_images := client.rest.select "service_images"
          print "Service images after 2nd attempt: $service_images"
        expect false

      // We keep the service version for the download test.
      run_main_test test_cli tmp_dir service_version --keep_service:
        uploader.main
            --config=test_cli.config
            --cache=test_cli.cache
            --ui=ui
            [
              "service",
              "--sdk-version", sdk_version,
              "--service-version", service_version,
              "--snapshot-directory", tmp_dir,
              "--force",
            ]

      // Try with a specific commit.
      commit_version := "$service_version-$(TEST_COMMIT)"
      run_main_test test_cli tmp_dir commit_version:
        uploader.main
            --config=test_cli.config
            --cache=test_cli.cache
            --ui=ui
            [
              "service",
              "--sdk-version", sdk_version,
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
            --ui=ui
            [
              "service",
              "--sdk-version", sdk_version,
              "--service-version", local_version,
              "--local",
              "--snapshot-directory", tmp_dir,
            ]

      // Without service version.
      run_main_test test_cli tmp_dir ARTEMIS_VERSION:
        uploader.main
            --config=test_cli.config
            --cache=test_cli.cache
            --ui=ui
            [
              "service",
              "--sdk-version", sdk_version,
              "--local",
              "--snapshot-directory", tmp_dir,
            ]

    finally:
      git.tag --delete --name=service_version

    // Download a service.
    downloader.main
        --config=test_cli.config
        --cache=test_cli.cache
        --ui=ui
        [
          "--sdk-version", sdk_version,
          "--service-version", service_version,
          "--output-directory", tmp_dir,
        ]

    // Check that the file was downloaded.
    files_iterator := directory.DirectoryStream tmp_dir
    files := []
    while file_name := files_iterator.next: files.add file_name
    files_iterator.close
    expect_equals 1 files.size

    delete_service_version test_cli service_version

expect_exit_1 [block]:
  exception := catch: block.call
  expect exception is TestExit
