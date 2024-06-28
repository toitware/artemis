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
  recovery-url-prefix_/string? := null
  recovery-url/string? := null

  attempt := 0
  start --fleet-id/uuid.Uuid -> none:
    network := net.open
    // Listen on a free port.
    tcp-socket := network.tcp-listen 0
    recovery-url-prefix_ = "http://localhost:$tcp-socket.local-address.port"
    server := http.Server
    recovery-path := "/recover-$(fleet-id).json"
    recovery-url = "$recovery-url-prefix_$recovery-path"

    task_ = task::
      server.listen tcp-socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
        resource := request.query.resource
        writer.headers.set "Content-Type" "text/plain"
        if resource == READY-TO-RECOVER-PATH:
          device-made-contact.set true
          recover-latch.get
        else:
          attempt++
          if attempt == 1:
            writer.write-headers http.STATUS-NOT-FOUND
            writer.out.write "Not found\n"
          else if attempt == 2:
            // Blank page.
            writer.write-headers http.STATUS-OK
          else if attempt == 3:
            // Bad json.
            writer.write-headers http.STATUS-OK
            writer.out.write "Not json\n"
          else if recovery-info and resource == recovery-path:
            writer.out.write recovery-info
          else:
            writer.write-headers http.STATUS-BAD-REQUEST
            writer.out.write "Not found\n"
        writer.close
    return

  ready-to-recover-url -> string:
    return "$recovery-url-prefix_$READY-TO-RECOVER-PATH"

  close:
    if task_:
      task_.cancel
      task_ = null

main args:
    // We can't create host-devices on Windows.
  if system.platform == system.PLATFORM-WINDOWS: return

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
    recovery-path := "$fleet.test-cli.tmp-dir/recover-$(fleet.id).json"
    fleet.run ["fleet", "recovery", "export", "-o", recovery-path]
    recovery-info := file.read-content recovery-path
    recovery-server.recovery-info = recovery-info

    test-device.wait-for-synchronized  // Still on the old broker.
    recovery-server.device-made-contact.get
    fleet.test-cli.stop-main-broker
    recovery-server.recover-latch.set true  // Let the HTTP server respond.

    test-device.wait-for "connecting {safe-mode: true}"
    test-device.wait-for "recovery query failed" // Followed by the URL and the 404.
    test-device.wait-for "status: 404"
    test-device.wait-for "recovery query failed" // Followed by the URL and the error below.
    test-device.wait-for "error: EMPTY_READER"
    test-device.wait-for "recovery query failed" // Followed by the URL and the error below.
    test-device.wait-for "error: INVALID_JSON_CHARACTER"

    test-device.wait-to-be-on-pod new-pod-id

    recovery-server.close
