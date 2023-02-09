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
  if $depth is given, the repository is shallow-cloned with the given depth.
  */
  clone url/string
      --out/string
      --depth/int?=null
      --ref/string?=null
      --config/Map?=null:
    args := [
      "git",
      "clone",
      url,
      out,
    ]
    if depth:
      args.add "--depth"
      args.add depth.stringify
    if ref:
      args.add "--branch"
      args.add ref
    if config:
      config.do: | key value |
        args.add "--config"
        args.add "$key=$value"

    exit_value := pipe.run_program args
    if not exit_value: throw "Clone of $url failed."

  /**
  Fetches the given $ref from the given $remote in the Git repository
    at the given $repository_root.

  If $depth is given, the repository is shallow-cloned with the given depth.
  If $force is given, the ref is fetched with --force.
  */
  fetch --ref/string --remote/string="origin"
      --repository_root/string=current_repository_root
      --depth/int?=null
      --force/bool=false:
    args := [
      "git",
      "-C", repository_root,
      "fetch",
      remote,
      // TODO(florian): is the following also useful in the
      // general context?
      "$ref:refs/remotes/$remote/$ref",
    ]
    if depth:
      args.add "--depth"
      args.add depth.stringify
    if force:
      args.add "--force"

    exit_value := pipe.run_program args
    if not exit_value: throw "Fetch of $ref from $remote failed."

  /**
  Tags the given $commit with the given tag $name.
  */
  tag --commit/string --name/string --repository_root/string=current_repository_root:
    pipe.backticks [
      "git",
      "-C", repository_root.copy,
      "tag",
      name,
      commit,
    ]

  /**
  Deletes the tag with the given $name.
  */
  tag --delete/bool --name/string --repository_root/string=current_repository_root:
    if not delete: throw "INVALID_ARGUMENT"
    pipe.backticks [
      "git",
      "-C", repository_root,
      "tag",
      "-d",
      name,
    ]

  /**
  Updates the tag with the given $name to point to the given $ref.

  If $force is given, the tag is updated with --force.
  */
  tag --update/bool
      --name/string
      --ref/string
      --repository_root/string=current_repository_root
      --force/bool=false:
    if not update: throw "INVALID_ARGUMENT"
    args := [
      "git",
      "-C", repository_root,
      "tag",
      name,
      ref,
    ]
    if force:
      args.add "--force"

    exit_value := pipe.run_program args
    if not exit_value: throw "Tag update failed."
