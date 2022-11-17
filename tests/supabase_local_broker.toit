// Copyright (C) 2022 Toitware ApS.

import host.pipe
import host.os

with_supabase [block]:
  supabase_exe := os.env.get "SUPABASE_EXE" or "supabase"
  out := pipe.backticks supabase_exe "status"
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
  block.call host anon_key
