// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.file
import host.directory
import host.pipe
import host.os

snapshot_to_images snapshot_path/string -> List:
  // Create the two images.
  sdk := get_toit_sdk
  tmpdir := directory.mkdtemp "/tmp/artemis-snapshot-to-image-"
  image32 := "$tmpdir/image32"
  image64 := "$tmpdir/image64"

  try:
    pipe.run_program ["$sdk/tools/snapshot_to_image", "-m32", "--binary", "-o", image32, snapshot_path]
    pipe.run_program ["$sdk/tools/snapshot_to_image", "-m64", "--binary", "-o", image64, snapshot_path]
    return [ (file.read_content image32), (file.read_content image64) ]
  finally:
    catch: file.delete image32
    catch: file.delete image64
    directory.rmdir tmpdir

get_toit_sdk -> string:
  if os.env.contains "JAG_TOIT_REPO_PATH":
    repo := "$(os.env["JAG_TOIT_REPO_PATH"])/build/host/sdk"
    if file.is_directory "$repo/bin" and file.is_directory "$repo/tools":
      return repo
    print_on_stderr_ "JAG_TOIT_REPO_PATH doesn't point to a built Toit repo"
    exit 1
  if os.env.contains "HOME":
    jaguar := "$(os.env["HOME"])/.cache/jaguar/sdk"
    if file.is_directory "$jaguar/bin" and file.is_directory "$jaguar/tools":
      return jaguar
    print_on_stderr_ "\$HOME/.cache/jaguar/sdk doesn't contain a Toit SDK"
    exit 1
  print_on_stderr_ "Did not find JAG_TOIT_REPO_PATH or a Jaguar installation"
  exit 1
  unreachable
