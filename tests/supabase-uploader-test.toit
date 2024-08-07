// Copyright (C) 2022 Toitware ApS.

import expect show *
import host.directory
import host.file

import .utils
import .artemis-server
import ..tools.service-image-uploader.uploader as uploader
import ..tools.service-image-uploader.downloader as downloader
import artemis.shared.version show ARTEMIS-VERSION
import artemis.cli.git show Git
import supabase
import supabase.filter show equals

main args:
  // Start a Tester, since that will set up everything the way we want.
  with-tester --args=args --artemis-type="supabase":
    run-test it

// Just a commit that exists on main.
// It's safe to update the commit to a newer version.
TEST-COMMIT ::= "a521082f8f6f0ddfaf33ab55007ec8a51b659dff"

run-main-test
    tester/Tester
    tmp-dir/string
    service-version/string
    --keep-service/bool=false
    [block]:
  block.call
  supabase-backdoor := (tester.artemis.backdoor) as SupabaseBackdoor
  // Check that the service is available.
  supabase-backdoor.with-backdoor-client_: | client/supabase.Client |
    available-sdks := client.rest.select "sdk_service_versions" --filters=[
      equals "sdk_version" tester.sdk-version,
      equals "service_version" service-version,
    ]
    expect-not available-sdks.is-empty

  // Check that the snapshots were written into the snapshot directory.
  // We have two snapshots since we have two chip-families: esp32 and host.
  files-iterator := directory.DirectoryStream tmp-dir
  files := []
  while file-name := files-iterator.next: files.add file-name
  files-iterator.close
  expect-equals 2 files.size

  // Delete the files.
  file.delete "$tmp-dir/$files[0]"
  file.delete "$tmp-dir/$files[1]"

  // Check that the file was deleted.
  files-iterator = directory.DirectoryStream tmp-dir
  files = []
  while file-name := files-iterator.next: files.add file-name
  files-iterator.close
  expect-equals 0 files.size

  if not keep-service:
    delete-service-version tester service-version

delete-service-version tester/Tester service-version/string:
  supabase-backdoor := tester.artemis.backdoor as SupabaseBackdoor
  supabase-backdoor.with-backdoor-client_: | client/supabase.Client |
    client.rest.delete "artemis_services" --filters=[
      equals "version" "$service-version",
    ]

run-test tester/Tester:
  sdk-version := tester.sdk-version
  with-tmp-directory: | tmp-dir/string |
    ui := TestUi --no-quiet
    cli := tester.cli.with --ui=ui
    git := Git --cli=cli

    // Login using the CLI login.
    // The uploader reuses the same credentials.
    tester.run [
      "auth", "login",
      "--email", ADMIN-EMAIL,
      "--password", ADMIN-PASSWORD
    ]

    service-version := "v0.0.$(random)-TEST"

    // The test-server could have already been used.
    // We want to avoid duplicates, so we create a new version number.
    // This means that we create a new tag every time we run this test.
    // We try to remove it afterwards, but if the program is interrupted
    // we might leave a tag behind. In that case it's safe to delete
    // the tag manually.
    git.tag --name=service-version --commit=TEST-COMMIT
    try:
      // We keep the service for the next test.
      run-main-test tester tmp-dir service-version --keep-service:
        uploader.main
            --cli=cli
            [
              "service",
              "--sdk-version", sdk-version,
              "--service-version", service-version,
              "--snapshot-directory", tmp-dir,
            ]

      // Debug information to analyze flaky tests.
      supabase-backdoor := tester.artemis.backdoor as SupabaseBackdoor
      supabase-backdoor.with-backdoor-client_: | client/supabase.Client |
        service-images := client.rest.select "service_images"
        print "Service images before 2nd attempt: $service-images"

      // Without force we can't upload the same version again.
      exception := catch:
        uploader.main
            --cli=cli
            [
              "service",
              "--sdk-version", sdk-version,
              "--service-version", service-version,
              "--snapshot-directory", tmp-dir,
            ]
      if exception is not TestExit:
        // Debug information to analyze flaky tests.
        supabase-backdoor.with-backdoor-client_: | client/supabase.Client |
          service-images := client.rest.select "service_images"
          print "Service images after 2nd attempt: $service-images"
        expect false

      // We keep the service version for the download test.
      run-main-test tester tmp-dir service-version --keep-service:
        uploader.main
            --cli=cli
            [
              "service",
              "--sdk-version", sdk-version,
              "--service-version", service-version,
              "--snapshot-directory", tmp-dir,
              "--force",
            ]

      // Try with a specific commit.
      commit-version := "$service-version-$(TEST-COMMIT)"
      run-main-test tester tmp-dir commit-version:
        uploader.main
            --cli=cli
            [
              "service",
              "--sdk-version", sdk-version,
              "--service-version", service-version,
              "--commit", TEST-COMMIT,
              "--snapshot-directory", tmp-dir,
            ]

      // Try with local.

      // With service version.
      local-version := "$service-version-$Time.now"
      run-main-test tester tmp-dir local-version:
        uploader.main
            --cli=cli
            [
              "service",
              "--sdk-version", sdk-version,
              "--service-version", local-version,
              "--local",
              "--snapshot-directory", tmp-dir,
            ]

      // Without service version.
      run-main-test tester tmp-dir ARTEMIS-VERSION:
        uploader.main
            --cli=cli
            [
              "service",
              "--sdk-version", sdk-version,
              "--local",
              "--snapshot-directory", tmp-dir,
            ]

    finally:
      git.tag --delete --name=service-version

    // Download a service.
    downloader.main
        --cli=cli
        [
          "--sdk-version", sdk-version,
          "--service-version", service-version,
          "--output-directory", tmp-dir,
        ]

    // Check that the file was downloaded.
    files-iterator := directory.DirectoryStream tmp-dir
    files := []
    while file-name := files-iterator.next: files.add file-name
    files-iterator.close
    // Two different snapshots due to two different chip families.
    expect-equals 2 files.size

    delete-service-version tester service-version

expect-exit-1 [block]:
  exception := catch: block.call
  expect exception is TestExit
