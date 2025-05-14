// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show Cli
import host.pipe
import io
import monitor

class Git:
  cli_/Cli

  constructor --cli/Cli:
    cli_ = cli

  /**
  Returns the root of the Git repository that contains the
    given $path. If no $path is given, uses the current working directory.
  */
  current-repository-root --path/string?=null -> string:
    args :=  path ? ["-C", path] : []
    args.add-all [
      "rev-parse",
      "--show-toplevel",
    ]
    out := run_ args
    return out.trim

  /**
  Inits a new Git repository in the given $repository-root.

  If $origin is given adds the given remote as "origin".
  */
  init repository-root/string --origin/string?=null --quiet/bool?=false:
    args := [
      "init",
      "--initial-branch=main",
      repository-root,
    ]
    if quiet:
      args.add "--quiet"

    run_ args --description="Init of $repository-root"

    if origin:
      args = [
        "-C", repository-root,
        "remote",
        "add",
        "origin",
        origin,
      ]

      run_ args --description="Remote-add of $origin in $repository-root"

  /**
  Sets the configuration $key to $value in the given $repository-root.

  If $global is true, the configuration is set globally.
  */
  config --key/string --value/string --repository-root/string=current-repository-root --global/bool=false:
    args := [
      "-C", repository-root,
      "config",
      key,
      value,
    ]
    if global:
      args.add "--global"

    run_ args --description="Config of $key in $repository-root"

  /**
  Fetches the given $ref from the given $remote in the Git repository
    at the given $repository-root.

  If $depth is given, the repository is shallow-cloned with the given depth.
  If $force is given, the ref is fetched with --force.

  If $checkout is true, the ref is checked out after fetching.
  */
  fetch --ref/string --remote/string="origin"
      --repository-root/string=current-repository-root
      --depth/int?=null
      --force/bool=false
      --checkout/bool=false
      --quiet/bool?=false:
    args := [
      "-C", repository-root,
      "remote",
      "-v",
    ]
    output := run_ args --description="Verbose remote"

    // Debug sleep, to make sure that the init/clone was finished.
    // TODO(florian): remove this again.
    sleep --ms=20

    args = [
      "-C", repository-root,
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
    if quiet:
      args.add "--quiet"

    try:
      run_ args --description="Fetch of $ref from $remote"
    finally: | is-exception _ |
      if is-exception:
        cli_.ui.emit --error "Verbose remote was: $output"

    if checkout:
      args = [
        "-C", repository-root,
        "checkout",
        ref,
      ]
      if quiet:
        args.add "--quiet"

      run_ args --description="Checkout of $ref"

  /**
  Tags the given $commit with the given tag $name.
  */
  tag --commit/string --name/string --repository-root/string=current-repository-root:
    run_ --description="Tag of $name" [
      "-C", repository-root.copy,
      "tag",
      "--no-sign",
      name,
      commit,
    ]

  /**
  Deletes the tag with the given $name.
  */
  tag --delete/bool --name/string --repository-root/string=current-repository-root:
    if not delete: throw "INVALID_ARGUMENT"
    run_ --description="Tag delete" [
      "-C", repository-root,
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
      --repository-root/string=current-repository-root
      --force/bool=false:
    if not update: throw "INVALID_ARGUMENT"
    args := [
      "-C", repository-root,
      "tag",
      "--no-sign",
      name,
      ref,
    ]
    if force:
      args.add "--force"

    run_ args --description="Tag update"

  /**
  Runs the command, and only outputs stdout/stderr if there is an error.
  */
  run_ args/List --description/string="Git command" -> string:
    output := io.Buffer
    stdout := io.Buffer
    fork-data := pipe.fork
        --environment=git-env_
        true                // use_path
        pipe.PIPE-INHERITED // stdin
        pipe.PIPE-CREATED   // stdout
        pipe.PIPE-CREATED   // stderr
        "git"
        ["git"] + args

    stdout-pipe := fork-data[1]
    stderr-pipe := fork-data[2]
    pid := fork-data[3]

    semaphore := monitor.Semaphore
    stdout-task := task::
      catch --trace:
        while chunk := stdout-pipe.read:
          output.write chunk
          stdout.write chunk
      semaphore.up

    stderr-task := task::
      catch --trace:
        while chunk := stderr-pipe.read:
          output.write chunk
      semaphore.up

    2.repeat: semaphore.down
    exit-value := pipe.wait-for pid

    if (pipe.exit-code exit-value) != 0:
      cli_.ui.emit --error "$description failed"
      cli_.ui.emit --error "Git arguments: $args"
      cli_.ui.emit --error output.bytes.to-string-non-throwing
      cli_.ui.abort

    return stdout.bytes.to-string-non-throwing

  git-env_ -> Map:
    return {
      "GIT_TERMINAL_PROMPT": "0",  // Disable stdin.
    }
