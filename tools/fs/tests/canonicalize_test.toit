// Copyright (C) 2023 Toitware ApS.

import expect show *
import fs

CANONICALIZE_LINUX_TESTS ::= [
  ["foo", "foo"],
  [".", "."],
  ["/", "/"],
  ["./foo", "foo"],
  ["../foo", "../foo"],
  ["foo/./bar", "foo/bar"],
  ["foo/////bar", "foo/bar"],
  ["///foo", "/foo"],
  ["foo/../bar/gee", "bar/gee"],
]

CANONICALIZE_WINDOWS_TESTS ::= [
  ["foo", "foo"],
  [".", "."],
  ["/", "/"],
  ["./foo", "foo"],
  ["../foo", "../foo"],
  ["foo/./bar", "foo/bar"],
  ["foo/////bar", "foo/bar"],
  ["foo/../bar/gee", "bar/gee"],
  ["\\", "/"],
  [".\\foo", "foo"],
  ["..\\foo", "../foo"],
  ["foo\\.\\bar", "foo/bar"],
  ["foo\\\\\\\\bar", "foo/bar"],
  ["\\foo", "/foo"],
  ["foo\\..\\bar/gee", "bar/gee"],
  ["c:foo", "c:foo"],
  ["c:../foo", "c:../foo"],
  ["c:\\foo/bar", "c:/foo/bar"],
  ["c://foo/bar", "c:/foo/bar"],
  ["c:/../foo/bar", "c:/foo/bar"],
  ["//foo/bar", "//foo/bar"],
  ["///foo", "//foo"],
  ["\\\\foo/bar", "//foo/bar"],
  ["/\\foo/bar", "/foo/bar"],
  ["\\/foo/bar", "/foo/bar"],
]

main:
  2.repeat:
    tests := it == 0 ? CANONICALIZE_LINUX_TESTS : CANONICALIZE_WINDOWS_TESTS
    path_platform := it == 0 ? PLATFORM_LINUX : PLATFORM_WINDOWS
    tests.do: | test/List |
      input := test[0]
      expected := test[1]
      actual := fs.canonicalize input --path_platform=path_platform
      expect_equals expected actual
