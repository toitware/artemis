import net
import encoding.json
import host.pipe

main:
  print get_external_ip

get_external_ip -> string:
  if platform == PLATFORM_LINUX:
    return get_external_ip_linux
  else if platform == PLATFORM_MACOS:
    return get_external_ip_macos
  print "Platform '$platform' is not supported."
  exit 1
  unreachable

get_external_ip_linux -> string:
  // Get the external IP.
  route_out := pipe.backticks "ip" "-j" "route" "get" "1"
  decoded := json.parse route_out
  external_ip := decoded[0]["prefsrc"]
  if not external_ip:
    print "Could not get external IP."
    exit 1
  return external_ip

get_external_ip_macos -> string:
  // First find the default interface name using route.
  route_out := pipe.backticks "route" "-n" "get" "default"
  interface_name := ""
  (route_out.split "\n").do: | line/string |
    line = line.trim
    if line.starts_with "interface":
      colon_index := line.index_of ":"
      if colon_index >= 0:
        interface_name = line[colon_index + 1 ..].trim
  // Then use ipconfig get the address.
  ipconfig_out := pipe.backticks "ipconfig" "getifaddr" interface_name
  external_ip := ipconfig_out.trim
  return external_ip
