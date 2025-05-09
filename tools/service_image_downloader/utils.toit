// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate-roots
import cli show Cli Invocation
import host.file
import host.directory
import supabase

import artemis.cli.config show
    CONFIG-ARTEMIS-DEFAULT-KEY
    CONFIG-SERVER-AUTHS-KEY
    ConfigLocalStorage
import artemis.cli.server-config show *

with-supabase-client invocation/Invocation [block]:
  cli := invocation.cli
  server-config := get-server-from-config --key=CONFIG-ARTEMIS-DEFAULT-KEY --cli=cli
  local-storage := ConfigLocalStorage
      --auth-key="$(CONFIG-SERVER-AUTHS-KEY).$(server-config.name)"
      --cli=cli
  supabase-config := server-config as supabase.ServerConfig
  client := supabase.Client
      --server-config=supabase-config
      --local-storage=local-storage
  try:
    block.call client
  finally:
    client.close

with-tmp-directory [block]:
  tmp-dir := directory.mkdtemp "/tmp/artemis-uploader-"
  try:
    block.call tmp-dir
  finally:
    directory.rmdir --recursive tmp-dir

write-file --path/string contents:
  stream := file.Stream.for-write path
  try:
    stream.out.write contents
  finally:
    stream.close
