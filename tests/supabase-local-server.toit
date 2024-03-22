// Copyright (C) 2022 Toitware ApS.

import encoding.json
import host.pipe
import host.os
import host.directory
import system
import artemis.shared.server-config show ServerConfigSupabase
import ..tools.lan-ip.lan-ip

SUPABASE-BROKER  ::= "../public/supabase_broker"
SUPABASE-ARTEMIS ::= "../supabase_artemis"

get-supabase-config --sub-directory/string -> ServerConfigSupabase:
  anon-key/string? := null
  api-url/string? := null

  out := get-status_ sub-directory
  lines := out.split "\n"
  lines.map --in-place: it.trim
  lines.do:
    if it.starts-with "anon key:":
      anon-key = it[(it.index-of ":") + 1..].trim
    else if it.starts-with "API URL:":
      api-url = it[(it.index-of ":") + 1..].trim

  if not anon-key or not api-url:
    throw "Could not get supabase info"

  host := api-url.trim --left "http://"
  print-on-stderr_ "HOST: $host ANON_KEY: $anon-key"
  name := sub-directory.trim --left "../"

  if system.platform != system.PLATFORM-WINDOWS:
    lan-ip := get-lan-ip
    host = host.replace "localhost" lan-ip
    host = host.replace "127.0.0.1" lan-ip

  return ServerConfigSupabase name --host=host --anon=anon-key

get-supabase-service-key --sub-directory/string -> string:
  out := get-status_ sub-directory
  lines := out.split "\n"
  lines.map --in-place: it.trim
  lines.do:
    if it.starts-with "service_role key:":
      return it[(it.index-of ":") + 1..].trim
  unreachable

get-status_ sub-directory/string -> string:
  supabase-exe := os.env.get "SUPABASE_EXE" or "supabase"
  return pipe.backticks supabase-exe "--workdir" "$sub-directory" "status"

// Prints the arguments needed for adding the local supabase service to the configuration.
main args:
  if args.size != 1:
    print "Usage: supabase_local_server.toit <supabase_directory>"
    exit 1

  sub-directory := args[0]
  config := get-supabase-config --sub-directory=sub-directory

  print "$config.host $config.anon"
