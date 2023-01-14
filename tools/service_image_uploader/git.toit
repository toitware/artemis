// Copyright (C) 2023 Toitware ApS. All rights reserved.

import host.pipe

class Git:
  /**
  Returns the root of the Git repository that contains the
    current working directory.
  */
  current_repository_root -> string:
    out := pipe.backticks [
      "git",
      "rev-parse",
      "--show-toplevel"
    ]
    return out.trim

  /**
  Clones the Git repository at the given URL into the $out directory.

  If $ref is given, the repository is checked out at that ref.
  */
  clone url/string --out/string --ref/string?:
    print "Cloning $url into $out with ref $ref"
    pipe.backticks [
      "git",
      "clone",
        // TODO(florian): the following "copy" shouldn't be necessary, but
        // the pipe.backticks command currently only accepts "real" strings
        // and "ref" could be a string-slice.
        // Same for the copies below.
      url.copy,
      out.copy
    ]
    if ref:
      pipe.backticks [
        "git",
        "-C", out.copy,
        "checkout", ref.copy,
        "-q",
      ]
      print "checkout done"

  /**
  Tags the given $commit with the given tag $name.
  */
  tag --commit/string --name/string --repository_root/string=current_repository_root:
    pipe.backticks [
      "git",
      "-C", repository_root.copy,
      "tag",
      name.copy,
      commit.copy,
    ]

  /**
  Deletes the tag with the given $name.
  */
  tag --delete/bool --name/string --repository_root/string=current_repository_root:
    if not delete: throw "INVALID_ARGUMENT"
    pipe.backticks [
      "git",
      "-C", repository_root.copy,
      "tag",
      "-d",
      name.copy,
    ]
