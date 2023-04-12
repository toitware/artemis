// Copyright (C) 2023 Toitware ApS. All rights reserved.

import bytes
import host.pipe
import .ui

class Git:
  ui_/Ui

  constructor --ui/Ui:
    ui_ = ui

  /**
  Returns the root of the Git repository that contains the
    current working directory.
  */
  current_repository_root -> string:
    out := run_ [
      "rev-parse",
      "--show-toplevel"
    ]
    return out.trim

  /**
  Inits a new Git repository in the given $repository_root.

  If $origin is given adds the given remote as "origin".
  */
  init repository_root/string --origin/string?=null --quiet/bool?=false:
    args := [
      "init",
      "--initial-branch=main",
      repository_root,
    ]
    if quiet:
      args.add "--quiet"

    run_ args --description="Init of $repository_root"

    if origin:
      args = [
        "-C", repository_root,
        "remote",
        "add",
        "origin",
        origin,
      ]

      run_ args --description="Remote-add of $origin in $repository_root"

  /**
  Sets the configuration $key to $value in the given $repository_root.

  If $global is true, the configuration is set globally.
  */
  config --key/string --value/string --repository_root/string=current_repository_root --global/bool=false:
    args := [
      "-C", repository_root,
      "config",
      key,
      value,
    ]
    if global:
      args.add "--global"

    run_ args --description="Config of $key in $repository_root"

  /**
  Fetches the given $ref from the given $remote in the Git repository
    at the given $repository_root.

  If $depth is given, the repository is shallow-cloned with the given depth.
  If $force is given, the ref is fetched with --force.

  If $checkout is true, the ref is checked out after fetching.
  */
  fetch --ref/string --remote/string="origin"
      --repository_root/string=current_repository_root
      --depth/int?=null
      --force/bool=false
      --checkout/bool=false
      --quiet/bool?=false:
    args := [
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
    if quiet:
      args.add "--quiet"

    run_ args --description="Fetch of $ref from $remote"

    if checkout:
      args = [
        "-C", repository_root,
        "checkout",
        ref,
      ]
      if quiet:
        args.add "--quiet"

      run_ args --description="Checkout of $ref"

  /**
  Tags the given $commit with the given tag $name.
  */
  tag --commit/string --name/string --repository_root/string=current_repository_root:
    run_ --description="Tag of $name" [
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
    run_ --description="Tag delete" [
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
      "-C", repository_root,
      "tag",
      name,
      ref,
    ]
    if force:
      args.add "--force"

    run_ args --description="Tag update"

  /**
  Runs the command, and only outputs stdout/stderr if there is an error.
  */
  run_ args/List -> string:
    return run_ args --description="Git command"

  run_ args/List --description -> string:
    output := bytes.Buffer
    stdout := bytes.Buffer
    fork_data := pipe.fork
        --environment=git_env_
        true                // use_path
        pipe.PIPE_INHERITED // stdin
        pipe.PIPE_CREATED   // stdout
        pipe.PIPE_CREATED   // stderr
        "git"
        ["git"] + args

    stdout_pipe := fork_data[1]
    stderr_pipe := fork_data[2]
    pid := fork_data[3]

    stdout_task := task::
      catch --trace:
        while chunk := stdout_pipe.read:
          output.write chunk
          stdout.write chunk

    stderr_task := task::
      catch --trace:
        while chunk := stderr_pipe.read:
          output.write chunk

    exit_value := pipe.wait_for pid
    stdout_task.cancel
    stderr_task.cancel

    if (pipe.exit_code exit_value) != 0:
      ui_.info output.bytes.to_string_non_throwing
      ui_.error "$description failed"
      ui_.error "Git arguments: $args"
      ui_.abort

    return stdout.bytes.to_string_non_throwing

  git_env_ -> Map:
    return {
      "GIT_TERMINAL_PROMPT": "0",  // Disable stdin.
    }
