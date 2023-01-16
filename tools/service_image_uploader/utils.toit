// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import host.directory
import supabase

import artemis.cli.config as cli
import artemis.cli.config show
    CONFIG_ARTEMIS_DEFAULT_KEY
    CONFIG_SERVER_AUTHS_KEY
    ConfigLocalStorage
import artemis.cli.server_config show *

with_supabase_client parsed/cli.Parsed config/cli.Config [block]:
  server_config := get_server_from_config config parsed["server"] CONFIG_ARTEMIS_DEFAULT_KEY
  local_storage := ConfigLocalStorage config --auth_key="$(CONFIG_SERVER_AUTHS_KEY).$(server_config.name)"
  supabase_config := server_config as supabase.ServerConfig
  client := supabase.Client
      --server_config=supabase_config
      --local_storage=local_storage
      --certificate_provider=: certificate_roots.MAP[it]
  try:
    block.call client
  finally:
    client.close

with_tmp_directory [block]:
  tmp_dir := directory.mkdtemp "/tmp/artemis-uploader-"
  try:
    block.call tmp_dir
  finally:
    directory.rmdir --recursive tmp_dir
