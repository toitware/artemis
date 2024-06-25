// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.base64
import certificate-roots
import cli
import host.file

import ..server-config
import ..cache
import ..config
import ..ui
import ...shared.server-config

create-config-commands config/Config cache/Cache ui/Ui -> List:
  config-cmd := cli.Command "config"
      --help="Configure Artemis tool."

  show-cmd := cli.Command "show"
      --help="Prints the current configuration."
      --run=:: show-config config ui
  config-cmd.add show-cmd

  (create-server-config-commands config ui).do: config-cmd.add it
  (create-recovery-config-commands config cache ui).do: config-cmd.add it

  return [config-cmd]

create-server-config-commands config/Config ui/Ui -> List:
  config-broker-cmd := cli.Command "broker"
      --help="Configure the Artemis brokers."
      --options=[
        cli.Flag "artemis"
            --help="Manipulate the config of the Artemis server."
            --hidden
      ]

  config-broker-cmd.add
      cli.Command "default"
          --help="""
            Show or set the default broker.

            The default broker is used when initializing a new fleet directory.

            If no broker is specified, the current default broker is shown.
            If a broker is specified, it is set as the default broker.

            If the '--clear' flag is specified, clears the default broker.
            """
          --options=[
            cli.Flag "clear"
                --help="Clear the default broker.",
          ]
          --rest=[
            cli.OptionString "name"
                --help="The name of the broker."
          ]
          --examples=[
            cli.Example "Prints the current default broker (if any):"
                --arguments="",
            cli.Example "Set the default broker to 'my-broker':"
                --arguments="my-broker",
          ]
          --run=:: default-server it config ui

  add-cmd := cli.Command "add"
      --help="Add a broker."
      --options=[
        cli.Flag "default"
            --default=true
            --help="Set the broker as the default broker.",
      ]
  config-broker-cmd.add add-cmd

  add-cmd.add
      cli.Command "supabase"
          --help="Add a Supabase broker."
          --options=[
            cli.OptionString "certificate"
                --help="The certificate to use for the broker.",
          ]
          --rest=[
            cli.OptionString "name"
                --help="The name of the broker."
                --required,
            cli.OptionString "host"
                --help="The host of the broker."
                --required,
            cli.OptionString "anon"
                --help="The key for anonymous access."
                --required,
          ]
          --examples=[
            cli.Example "Add a local Supabase broker (anon-token is truncated):"
                --arguments="my-local-supabase 127.0.0.1:54321 eyJhb...6XHc",
            cli.Example "Add a Supabase broker with a certificate (anon-token is truncated):"
                --arguments="my-remote-broker --certificate=\"Baltimore CyberTrust Root\" voisfafsfolxhqpkudzd.subabase.co eyJh...j2e4",
          ]
          --run=:: add-supabase it config ui

  add-cmd.add
      cli.Command "http"
          --help="Add an HTTP broker."
          --options=[
            cli.OptionInt "port"
                --help="The port of the broker."
                --short-name="p"
                --required,
            cli.Option "host"
                --help="The host of the broker."
                --short-name="h"
                --default="localhost",
            cli.Option "path"
                --help="The path of the broker."
                --default="/",
            cli.Option "root-certificate"
                --help="The root certificate name of the broker."
                --multi,
            cli.Option "device-header"
                --help="The HTTP header the device needs to add to the request. Of the form KEY=VALUE."
                --multi,
            cli.Option "admin-header"
                --help="The HTTP header the CLI needs to add to the request. Of the form KEY=VALUE."
                --multi,
          ]
          --rest=[
            cli.OptionString "name"
                --help="The name of the broker."
                --required,
          ]
          --run=:: add-http it config ui

  return [config-broker-cmd]

create-recovery-config-commands config/Config cache/Cache ui/Ui -> List:
  recovery-cmd := cli.Command "recovery"
      --help="""
          Configure default recovery servers.

          Default recovery servers are automatically set when creating a new fleet. The
            URLs in the configuration are used as a prefix, with 'recover-<FLEET-ID>.json'
            appended to the URL to create the full recovery URL.

          See the 'fleet recovery' documentation for more information.
          """

  recovery-add-cmd := cli.Command "add"
      --help="""
          Add a default recovery server.
          """
      --rest=[
        cli.OptionString "url"
            --help="The URL of the server."
            --required,
      ]
      --examples=[
        cli.Example "Add a recovery server:"
            --arguments="https://recovery.example.com",
      ]
      --run=:: add-recovery-server it config ui
  recovery-cmd.add recovery-add-cmd

  recovery-list-cmd := cli.Command "list"
      --aliases=["ls"]
      --help="List the recovery servers."
      --run=:: list-recovery-servers config ui
  recovery-cmd.add recovery-list-cmd

  recovery-remove-cmd := cli.Command "remove"
      --help="Remove a default recovery server."
      --options=[
        cli.Flag "all"
            --help="Remove all servers.",
        cli.Flag "force"
            --short-name="f"
            --help="Do not error if the server doesn't exist.",
      ]
      --rest=[
        cli.OptionString "url"
            --help="The URL of the server."
            --multi,
      ]
      --examples=[
        cli.Example "Remove a recovery server:"
            --arguments="https://recovery.example.com",
      ]
      --run=:: remove-recovery-servers it config ui
  recovery-cmd.add recovery-remove-cmd

  return [recovery-cmd]

show-config config/Config ui/Ui:
  default-device := config.get CONFIG-DEVICE-DEFAULT-KEY
  default-broker := config.get CONFIG-BROKER-DEFAULT-KEY
  default-org := config.get CONFIG-ORGANIZATION-DEFAULT-KEY
  servers := config.get CONFIG-SERVERS-KEY
  auths := config.get CONFIG-SERVER-AUTHS-KEY
  recovery-urls := config.get CONFIG-RECOVERY-SERVERS-KEY

  json-output := :
    result := {
      "path" : config.path
    }

    if default-device: result["default-device"] = default-device
    if default-broker: result["default-broker"] = default-broker
    if default-org: result["default-org"] = default-org
    if servers: result["servers"] = servers
    if auths:
      // Store the auths with the servers.
      result-servers := result.get "servers" --init=: {:}
      auths.do: | server-name auth |
        server := result-servers.get server-name --init=: {:}
        if auth is Map:
          ["access_token", "refresh_token"].do: | token-name |
            if auth.contains token-name and auth[token-name].size > 35:
              auth[token-name] = auth[token-name][0..30] + "..."
        server["auth"] = auth
    if recovery-urls: result["recovery-servers"] = recovery-urls
    result

  human-output := : | printer/Printer |
    result := {
      "Configuration file" : config.path
    }
    if default-device: result["Default device"] = default-device
    if default-broker: result["Default broker"] = default-broker
    if default-org: result["Default organization"] = default-org
    if servers:
      // TODO(florian): make the servers nicer.
      result["Servers"] = servers
    if auths:
      // Store the auths with the servers.
      result-servers := result.get "Servers" --init=: {:}
      auths.do: | server-name auth |
        server := result-servers.get server-name --init=: {:}
        server["auth"] = auth
    if recovery-urls: result["Recovery servers"] = recovery-urls
    printer.emit result

  ui.do --kind=Ui.RESULT: | printer/Printer |
    printer.emit-structured
        --json=json-output
        --stdout=human-output

default-server parsed/cli.Parsed config/Config ui/Ui:
  config-key := parsed["artemis"] ? CONFIG-ARTEMIS-DEFAULT-KEY : CONFIG-BROKER-DEFAULT-KEY

  if parsed["clear"]:
    config.remove config-key
    config.write
    return

  name := parsed["name"]
  if not name:
    default-server := config.get config-key
    if default-server:
      ui.result default-server
    else:
      ui.abort "No default broker."
    return

  if not has-server-in-config config name:
    ui.abort "Unknown broker '$name'."

  config[config-key] = name
  config.write

check-certificate_ name/string ui/Ui -> none:
  certificate := certificate-roots.MAP.get name
  if certificate: return
  ui.error "Unknown certificate."
  ui.do: | printer/Printer |
    printer.emit --title="Available certificates:"
      certificate-roots.MAP.keys
  ui.abort

add-supabase parsed/cli.Parsed config/Config ui/Ui:
  name := parsed["name"]
  host := parsed["host"]
  anon := parsed["anon"]
  certificate-name := parsed["certificate"]

  if host.starts-with "http://" or host.starts-with "https://":
    host = host.trim --prefix "http://"
    host = host.trim --prefix "https://"

  supabase-config := ServerConfigSupabase name
      --host=host
      --anon=anon
      --root-certificate-name=certificate-name

  add-server-to-config config supabase-config
  if parsed["default"]:
    config[CONFIG-BROKER-DEFAULT-KEY] = name
  config.write

  ui.info "Added broker '$name'."

add-http parsed/cli.Parsed config/Config ui/Ui:
  name := parsed["name"]
  host := parsed["host"]
  port := parsed["port"]
  path := parsed["path"]
  root-certificate-names := parsed["root-certificate"]
  device-headers-list := parsed["device-header"]
  admin-headers-list := parsed["admin-header"]

  root-certificate-names.do: check-certificate_ it ui
  if root-certificate-names.is-empty:
    root-certificate-names = null

  header-list-to-map := : | header-list/List |
    headers-map := null
    if not header-list.is-empty:
      headers-map = {:}
      header-list.do: | header/string |
        equal-index := header.index-of "="
        if equal-index == -1:
          ui.abort "Invalid header: $header"
        key := header[..equal-index]
        value := header[equal-index + 1..]
        if headers-map.contains key:
          ui.abort "Duplicate headers not implemented: $key"
        headers-map[key] = value
    headers-map

  device-headers := header-list-to-map.call device-headers-list
  admin-headers := header-list-to-map.call admin-headers-list

  http-config := ServerConfigHttp name
      --host=host
      --port=port
      --path=path
      --root-certificate-names=root-certificate-names
      --root-certificate-ders=null
      --device-headers=device-headers
      --admin-headers=admin-headers

  add-server-to-config config http-config
  if parsed["default"]:
    config[CONFIG-BROKER-DEFAULT-KEY] = name
  config.write

  ui.info "Added broker '$name'."

add-recovery-server parsed/cli.Parsed config/Config ui/Ui:
  url := parsed["url"]

  config-key := CONFIG-RECOVERY-SERVERS-KEY
  recovery-servers := config.get config-key --init=: []
  if recovery-servers.contains url:
    ui.abort "Recovery server already exists."
  recovery-servers.add url
  config[config-key] = recovery-servers
  config.write

  ui.info "Added recovery server '$url'."

list-recovery-servers config/Config ui/Ui:
  config-key := CONFIG-RECOVERY-SERVERS-KEY
  recovery-servers := config.get config-key or []

  ui.do --kind=Ui.RESULT: | printer/Printer |
    printer.emit --title="Recovery servers:"
      recovery-servers

remove-recovery-servers parsed/cli.Parsed config/Config ui/Ui:
  all := parsed["all"]
  urls := parsed["url"]
  force := parsed["force"]

  config-key := CONFIG-RECOVERY-SERVERS-KEY
  recovery-servers := config.get config-key --init=: []

  if all:
    recovery-servers.clear
    config[config-key] = recovery-servers
    config.write
    ui.info "Removed all recovery servers."
    return

  urls.do: | url |
    if not force and not recovery-servers.contains url:
      ui.abort "Recovery server not found."
    recovery-servers.remove url

  config[config-key] = recovery-servers
  config.write

  ui.info "Removed recovery server(s)."
