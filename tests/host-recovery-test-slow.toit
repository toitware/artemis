// Copyright (C) 2024 Toitware ApS.

import fs
import host.file
import http
import io
import monitor
import net
import system
import uuid

import .cli-device-extract show upload-pod
import .host-recovery-source show TEST-URL-ENV
import .utils

class RecoveryServer:
  static READY-TO-RECOVER-PATH ::= "/ready-to-recover"
  task_/Task? := null
  recovery-info/io.Data? := null
  device-made-contact/monitor.Latch := monitor.Latch
  recover-latch/monitor.Latch := monitor.Latch
  server-url_/string? := null

  start --fleet-id/uuid.Uuid -> none:
    network := net.open
    // Listen on a free port.
    tcp-socket := network.tcp-listen 0
    server-url_ = "http://localhost:$tcp-socket.local-address.port"
    server := http.Server
    task_ = task::
      server.listen tcp-socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
        resource := request.query.resource
        writer.headers.set "Content-Type" "text/plain"
        if resource == READY-TO-RECOVER-PATH:
          print "---- Device made contact ---"
          device-made-contact.set true
          recover-latch.get
          writer.out.write "Do it\n"
        else if recovery-info and resource == "/recover-$(fleet-id).json":
          writer.out.write recovery-info
        else:
          writer.write-headers 404
          writer.out.write "Not found\n"
        writer.close
    return

  recovery-url -> string:
    return "$server-url_"

  ready-to-recover-url -> string:
    return "$server-url_/ready-to-recover"

  close:
    if task_:
      task_.cancel
      task_ = null

main args:
  source-dir := fs.dirname system.program-path
  source := file.read-content "$source-dir/host-recovery-source.toit"

  with-fleet --count=0 --args=args: | fleet/TestFleet |
    recovery-server := RecoveryServer
    recovery-server.start --fleet-id=fleet.id

    fleet.run ["fleet", "recovery", "add", recovery-server.recovery-url]

    upload-pod
        --gold-name="recovery"
        --format="tar"
        --fleet=fleet
        --files={
          "host-recovery-source.toit": source,
        }
        --pod-spec={
          "containers": {
            "recovery": {
              "entrypoint": "host-recovery-source.toit",
            }
          }
        }
    test-device/TestDevicePipe := fleet.create-host-device "test-device" --no-start
    test-device.start --env={
      TEST_URL_ENV: recovery-server.ready-to-recover-url,
    }

    backup-broker := fleet.start-broker "backup"
    // The easiest way to update the broker information is to just do a migration.
    fleet.run ["fleet", "migration", "start", "--broker", backup-broker.name]
    fleet.run ["fleet", "migration", "stop", "--force"]  // We are now on the new broker.

    fleet-content := (file.read-content "$fleet.fleet-dir/fleet.json").to-string
    print fleet-content

    new-pod-id := fleet.upload-pod "on-new-broker" --format="tar"
    fleet.run ["fleet", "roll-out"]

    // Create recovery information for it.
    fleet.run ["fleet", "recovery", "export", "--directory", fleet.test-cli.tmp-dir]
    recovery-info := file.read-content "$fleet.test-cli.tmp-dir/recover-$(fleet.id).json"
    recovery-server.recovery-info = recovery-info

    test-device.wait-for-synchronized  // Still on the old broker.
    recovery-server.device-made-contact.get
    fleet.test-cli.stop-main-broker
    recovery-server.recover-latch.set true  // Let the HTTP server respond.

    test-device.wait-to-be-on-pod new-pod-id
