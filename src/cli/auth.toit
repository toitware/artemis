import http
import log
import net
import host.pipe
import monitor
import encoding.url as url_encoding
import encoding.json as json_encoding
import certificate_roots
import supabase

import .config
import ..shared.server_config

sign_in server_config/ServerConfig config/Config -> none:
  if server_config is not ServerConfigSupabase:
    throw "Unsupported broker type."

  print "server_config: $server_config.config_"
  supabase_config := server_config as ServerConfigSupabase

  local_storage := ConfigLocalStorage config
      --auth_key="$(CONFIG_SERVER_AUTHS_KEY).$(server_config.name)"

  client/supabase.Client? := null
  try:
    client = supabase.Client
        --local_storage=local_storage
        --server_config=supabase_config
        --certificate_provider=: certificate_roots.MAP[it]
    client.auth.sign_in --provider="github"
  finally:
    if client: client.close

refresh_token server_config/ServerConfig config/Config -> none:
  if server_config is not ServerConfigSupabase:
    throw "Unsupported broker type."

  supabase_config := server_config as ServerConfigSupabase

  local_storage := ConfigLocalStorage config
      --auth_key="$(CONFIG_SERVER_AUTHS_KEY).$(server_config.name)"

  client/supabase.Client? := null
  try:
    client = supabase.Client
        --local_storage=local_storage
        --server_config=supabase_config
        --certificate_provider=: certificate_roots.MAP[it]
    client.auth.refresh_token
  finally:
    if client: client.close
