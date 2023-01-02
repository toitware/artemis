// Copyright (C) 2022 Toitware ApS.

import host.pipe
import host.os
import host.directory
import artemis.shared.server_config show ServerConfigSupabase

SUPABASE_CUSTOMER ::= "supabase_customer"
SUPABASE_ARTEMIS ::= "../supabase_artemis"

get_supabase_config --sub_directory/string -> ServerConfigSupabase:
  // Here we are only interested in customer brokers.
  // We need to move into the customer-supabase directory to get its configuration.
  current_dir := directory.cwd
  directory.chdir "$current_dir/$sub_directory"
  out/string? := null
  try:
    supabase_exe := os.env.get "SUPABASE_EXE" or "supabase"
    out = pipe.backticks supabase_exe "status"
  finally:
    directory.chdir current_dir

  anon_key/string? := null
  api_url/string? := null

  lines := out.split "\n"
  lines.map --in_place: it.trim
  lines.do:
    if it.starts_with "anon key:":
      anon_key = it[(it.index_of ":") + 1..].trim
    else if it.starts_with "API URL:":
      api_url = it[(it.index_of ":") + 1..].trim

  if not anon_key or not api_url:
    throw "Could not get supabase info"

  host := api_url.trim --left "http://"
  print "HOST: $host ANON_KEY: $anon_key"
  name := sub_directory.trim --left "../"
  return ServerConfigSupabase name --host=host --anon=anon_key
