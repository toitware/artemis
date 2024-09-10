// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.base64
import certificate-roots
import cli show *
import host.file

import ..server-config
import ..cache
import ..config
import ...shared.server-config

create-config-commands -> List:
  config-cmd := Command "config"
      --help="Configure Artemis tool."

  show-cmd := Command "show"
      --help="Prints the current configuration."
      --run=:: show-config it
  config-cmd.add show-cmd

  create-server-config-commands.do: config-cmd.add it
  create-recovery-config-commands.do: config-cmd.add it

  return [config-cmd]

create-server-config-commands -> List:
  config-broker-cmd := Command "broker"
      --help="Configure the Artemis brokers."
      --options=[
        Flag "artemis"
            --help="Manipulate the config of the Artemis server."
            --hidden
      ]

  config-broker-cmd.add
      Command "default"
          --help="""
            Show or set the default broker.

            The default broker is used when initializing a new fleet directory.

            If no broker is specified, the current default broker is shown.
            If a broker is specified, it is set as the default broker.

            If the '--clear' flag is specified, clears the default broker.
            """
          --options=[
            Flag "clear"
                --help="Clear the default broker.",
          ]
          --rest=[
            Option "name"
                --help="The name of the broker."
          ]
          --examples=[
            Example "Prints the current default broker (if any):"
                --arguments="",
            Example "Set the default broker to 'my-broker':"
                --arguments="my-broker",
          ]
          --run=:: default-server it

  add-cmd := Command "add"
      --help="Add a broker."
      --options=[
        Flag "default"
            --default=true
            --help="Set the broker as the default broker.",
      ]
  config-broker-cmd.add add-cmd

  add-cmd.add
      Command "supabase"
          --help="Add a Supabase broker."
          --options=[
            Option "certificate"
                --help="The certificate to use for the broker.",
          ]
          --rest=[
            Option "name"
                --help="The name of the broker."
                --required,
            Option "host"
                --help="The host of the broker."
                --required,
            Option "anon"
                --help="The key for anonymous access."
                --required,
          ]
          --examples=[
            Example "Add a local Supabase broker (anon-token is truncated):"
                --arguments="my-local-supabase 127.0.0.1:54321 eyJhb...6XHc",
            Example "Add a Supabase broker with a certificate (anon-token is truncated):"
                --arguments="my-remote-broker --certificate=\"Baltimore CyberTrust Root\" voisfafsfolxhqpkudzd.subabase.co eyJh...j2e4",
          ]
          --run=:: add-supabase it

  add-cmd.add
      Command "http"
          --help="Add an HTTP broker."
          --options=[
            OptionInt "port"
                --help="The port of the broker."
                --short-name="p"
                --required,
            Option "host"
                --help="The host of the broker."
                --short-name="h"
                --default="localhost",
            Option "path"
                --help="The path of the broker."
                --default="/",
            Option "root-certificate"
                --help="The root certificate name of the broker."
                --multi,
            Option "device-header"
                --help="The HTTP header the device needs to add to the request. Of the form KEY=VALUE."
                --multi,
            Option "admin-header"
                --help="The HTTP header the CLI needs to add to the request. Of the form KEY=VALUE."
                --multi,
          ]
          --rest=[
            Option "name"
                --help="The name of the broker."
                --required,
          ]
          --run=:: add-http it

  return [config-broker-cmd]

create-recovery-config-commands -> List:
  recovery-cmd := Command "recovery"
      --help="""
          Configure default recovery servers.

          Default recovery servers are automatically set when creating a new fleet. The
            URLs in the configuration are used as a prefix, with 'recover-<FLEET-ID>.json'
            appended to the URL to create the full recovery URL.

          See the 'fleet recovery' documentation for more information.
          """

  recovery-add-cmd := Command "add"
      --help="""
          Add a default recovery server.
          """
      --rest=[
        Option "url"
            --help="The URL of the server."
            --required,
      ]
      --examples=[
        Example "Add a recovery server:"
            --arguments="https://recovery.example.com",
      ]
      --run=:: add-recovery-server it
  recovery-cmd.add recovery-add-cmd

  recovery-list-cmd := Command "list"
      --aliases=["ls"]
      --help="List the recovery servers."
      --run=:: list-recovery-servers it
  recovery-cmd.add recovery-list-cmd

  recovery-remove-cmd := Command "remove"
      --help="Remove a default recovery server."
      --options=[
        Flag "all"
            --help="Remove all servers.",
        Flag "force"
            --short-name="f"
            --help="Do not error if the server doesn't exist.",
      ]
      --rest=[
        Option "url"
            --help="The URL of the server."
            --multi,
      ]
      --examples=[
        Example "Remove a recovery server:"
            --arguments="https://recovery.example.com",
      ]
      --run=:: remove-recovery-servers it
  recovery-cmd.add recovery-remove-cmd

  return [recovery-cmd]

show-config invocation/Invocation:
  cli := invocation.cli
  config := cli.config
  ui := cli.ui

  default-device := config.get CONFIG-DEVICE-DEFAULT-KEY
  default-broker := config.get CONFIG-BROKER-DEFAULT-KEY
  default-org := config.get CONFIG-ORGANIZATION-DEFAULT-KEY
  servers := config.get CONFIG-SERVERS-KEY
  auths := config.get CONFIG-SERVER-AUTHS-KEY
  recovery-urls := config.get CONFIG-RECOVERY-SERVERS-KEY

  if ui.wants-structured:
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
    ui.emit-map result
  else:
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
    ui.emit-map result

default-server invocation/Invocation:
  cli := invocation.cli
  config := cli.config
  ui := cli.ui

  config-key := invocation["artemis"] ? CONFIG-ARTEMIS-DEFAULT-KEY : CONFIG-BROKER-DEFAULT-KEY

  if invocation["clear"]:
    config.remove config-key
    config.write
    return

  name := invocation["name"]
  if not name:
    default-server := config.get config-key
    if default-server:
      ui.result default-server
    else:
      ui.abort "No default broker."
    return

  if not has-server-in-config name --cli=cli:
    ui.abort "Unknown broker '$name'."

  config[config-key] = name
  config.write

check-certificate_ name/string --cli/Cli -> none:
  ui := cli.ui
  certificate := certificate-roots.MAP.get name
  if certificate: return
  ui.error "Unknown certificate."
  ui.emit-list certificate-roots.MAP.keys --kind=Ui.ERROR --title="Available certificates"
  ui.abort

add-supabase invocation/Invocation:
  cli := invocation.cli
  params := invocation.parameters
  config := cli.config
  ui := cli.ui

  name := params["name"]
  host := params["host"]
  anon := params["anon"]
  certificate-name := params["certificate"]

  if host.starts-with "http://" or host.starts-with "https://":
    host = host.trim --prefix "http://"
    host = host.trim --prefix "https://"

  supabase-config := ServerConfigSupabase name
      --host=host
      --anon=anon
      --root-certificate-name=certificate-name

  add-server-to-config supabase-config --cli=cli
  if params["default"]:
    config[CONFIG-BROKER-DEFAULT-KEY] = name
  config.write

  ui.inform "Added broker '$name'."

add-http invocation/Invocation:
  cli := invocation.cli
  params := invocation.parameters
  config := cli.config
  ui := cli.ui

  name := params["name"]
  host := params["host"]
  port := params["port"]
  path := params["path"]
  root-certificate-names := params["root-certificate"]
  device-headers-list := params["device-header"]
  admin-headers-list := params["admin-header"]

  root-certificate-names.do: check-certificate_ it --cli=cli
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

  add-server-to-config http-config --cli=cli
  if params["default"]:
    config[CONFIG-BROKER-DEFAULT-KEY] = name
  config.write

  ui.inform "Added broker '$name'."

add-recovery-server invocation/Invocation:
  config := invocation.cli.config
  ui := invocation.cli.ui

  url := invocation["url"]

  config-key := CONFIG-RECOVERY-SERVERS-KEY
  recovery-servers := config.get config-key --init=: []
  if recovery-servers.contains url:
    ui.abort "Recovery server already exists."
  recovery-servers.add url
  config[config-key] = recovery-servers
  config.write

  ui.inform "Added recovery server '$url'."

list-recovery-servers invocation/Invocation:
  config := invocation.cli.config
  ui := invocation.cli.ui

  config-key := CONFIG-RECOVERY-SERVERS-KEY
  recovery-servers := config.get config-key or []

  ui.emit-list
      --kind=Ui.RESULT
      --title="Recovery servers:"
      recovery-servers

remove-recovery-servers invocation/Invocation:
  cli := invocation.cli
  config := cli.config
  ui := cli.ui
  params := invocation.parameters

  all := params["all"]
  urls := params["url"]
  force := params["force"]

  config-key := CONFIG-RECOVERY-SERVERS-KEY
  recovery-servers := config.get config-key --init=: []

  if all:
    recovery-servers.clear
    config[config-key] = recovery-servers
    config.write
    ui.inform "Removed all recovery servers."
    return

  urls.do: | url |
    if not force and not recovery-servers.contains url:
      ui.abort "Recovery server not found."
    recovery-servers.remove url

  config[config-key] = recovery-servers
  config.write

  ui.inform "Removed recovery server(s)."
