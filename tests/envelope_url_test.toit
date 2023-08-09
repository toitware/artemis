// Copyright (C) 2023 Toitware ApS. All rights reserved.

import expect show *

import artemis.cli.firmware show build_envelope_url
import .utils

DOWNLOAD_URL ::="https://github.com/toitlang/toit/releases/download"

main:
  test_build_url

test_build_url:
  version := "v2.0.0-alpha.90"
  expect_equals "$DOWNLOAD_URL/$version/firmware-esp32.gz"
      build_envelope_url --sdk_version=version --envelope="esp32"

  expect_equals "$DOWNLOAD_URL/$version/firmware-esp32-eth-clk-out17.gz"
      build_envelope_url --sdk_version=version --envelope="esp32-eth-clk-out17"

  expect_equals "$DOWNLOAD_URL/$version/firmware-esp32-foobar.gz"
      build_envelope_url --sdk_version=version --envelope="esp32-foobar"

  expect_equals "file://foo/bar"
      build_envelope_url --sdk_version=null --envelope="foo/bar"

  expect_equals "file://foo/bar"
      build_envelope_url --sdk_version=null --envelope="file://foo/bar"

  expect_equals "file:///foo/bar"
      build_envelope_url --sdk_version=null --envelope="file:///foo/bar"

  expect_equals "file://c:\\foo\\bar"
      build_envelope_url --sdk_version=null --envelope="file://c:\\foo\\bar"

  expect_equals "file://c:\\foo\\bar"
      build_envelope_url --sdk_version=null --envelope="c:\\foo\\bar"

  expect_equals "https://foo/123/bar-xx"
      build_envelope_url --sdk_version="123" --envelope="https://foo/\$(sdk-version)/bar-xx"
