// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar
import certificate-roots
import cli
import host.file
import host.directory
import supabase

import artemis.cli.config as cli
import artemis.cli.ui as ui
import artemis.cli.config show
    CONFIG-ARTEMIS-DEFAULT-KEY
    CONFIG-SERVER-AUTHS-KEY
    ConfigLocalStorage
import artemis.cli.server-config show *

with-supabase-client parsed/cli.Parsed config/cli.Config ui/ui.Ui [block]:
  server-config := get-server-from-config config ui --key=CONFIG-ARTEMIS-DEFAULT-KEY
  local-storage := ConfigLocalStorage config --auth-key="$(CONFIG-SERVER-AUTHS-KEY).$(server-config.name)"
  supabase-config := server-config as supabase.ServerConfig
  client := supabase.Client
      --server-config=supabase-config
      --local-storage=local-storage
      --certificate-provider=: certificate-roots.MAP[it]
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

write-file --path/string content:
  stream := file.Stream.for-write path
  try:
    stream.out.write content
  finally:
    stream.close
