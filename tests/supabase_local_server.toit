// Copyright (C) 2022 Toitware ApS.

import encoding.json
import host.pipe
import host.os
import host.directory
import artemis.shared.server_config show ServerConfigSupabase

SUPABASE_CUSTOMER ::= "supabase_customer"
SUPABASE_ARTEMIS ::= "../supabase_artemis"

get_supabase_config --sub_directory/string -> ServerConfigSupabase:
  anon_key/string? := null
  api_url/string? := null

  out := get_status_ sub_directory
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
  print_on_stderr_ "HOST: $host ANON_KEY: $anon_key"
  name := sub_directory.trim --left "../"
  return ServerConfigSupabase name --host=host --anon=anon_key

get_supabase_service_key --sub_directory/string -> string:
  out := get_status_ sub_directory
  lines := out.split "\n"
  lines.map --in_place: it.trim
  lines.do:
    if it.starts_with "service_role key:":
      return it[(it.index_of ":") + 1..].trim
  unreachable

get_status_ sub_directory/string -> string:
  supabase_exe := os.env.get "SUPABASE_EXE" or "supabase"
  return pipe.backticks supabase_exe "--workdir" "$sub_directory" "status"

// Prints the arguments needed for adding the local supabase service to the configuration.
main args:
  if args.size != 1:
    print "Usage: supabase_local_server.toit <supabase_directory>"
    exit 1

  sub_directory := args[0]
  config := get_supabase_config --sub_directory=sub_directory

  if platform != PLATFORM_LINUX:
    print "Only linux is supported"
    exit 1

  // Get the external IP.
  route_out := pipe.backticks "ip" "-j" "route" "get" "1"
  decoded := json.parse route_out
  external_ip := decoded[0]["prefsrc"]
  if not external_ip:
    print "Could not get external IP"
    exit 1

  host := config.host.replace "localhost" external_ip
  print "$host $config.anon"
