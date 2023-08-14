// Copyright (C) 2023 Toitware ApS.

import expect show *
import fs

CANONICALIZE-LINUX-TESTS ::= [
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

CANONICALIZE-WINDOWS-TESTS ::= [
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
    tests := it == 0 ? CANONICALIZE-LINUX-TESTS : CANONICALIZE-WINDOWS-TESTS
    path-platform := it == 0 ? PLATFORM-LINUX : PLATFORM-WINDOWS
    tests.do: | test/List |
      input := test[0]
      expected := test[1]
      actual := fs.canonicalize input --path-platform=path-platform
      expect-equals expected actual
