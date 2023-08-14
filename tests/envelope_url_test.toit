// Copyright (C) 2023 Toitware ApS. All rights reserved.

import expect show *

import artemis.cli.firmware show build-envelope-url
import .utils

DOWNLOAD-URL ::="https://github.com/toitlang/toit/releases/download"

main:
  test-build-url

test-build-url:
  version := "v2.0.0-alpha.90"
  expect-equals "$DOWNLOAD-URL/$version/firmware-esp32.gz"
      build-envelope-url --sdk-version=version --envelope="esp32"

  expect-equals "$DOWNLOAD-URL/$version/firmware-esp32-eth-clk-out17.gz"
      build-envelope-url --sdk-version=version --envelope="esp32-eth-clk-out17"

  expect-equals "$DOWNLOAD-URL/$version/firmware-esp32-foobar.gz"
      build-envelope-url --sdk-version=version --envelope="esp32-foobar"

  expect-equals "file://foo/bar"
      build-envelope-url --sdk-version=null --envelope="foo/bar"

  expect-equals "file://foo/bar"
      build-envelope-url --sdk-version=null --envelope="file://foo/bar"

  expect-equals "file:///foo/bar"
      build-envelope-url --sdk-version=null --envelope="file:///foo/bar"

  expect-equals "file://c:\\foo\\bar"
      build-envelope-url --sdk-version=null --envelope="file://c:\\foo\\bar"

  expect-equals "file://c:\\foo\\bar"
      build-envelope-url --sdk-version=null --envelope="c:\\foo\\bar"

  expect-equals "https://foo/123/bar-xx"
      build-envelope-url --sdk-version="123" --envelope="https://foo/\$(sdk-version)/bar-xx"
