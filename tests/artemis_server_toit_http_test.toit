// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net

import ..tools.http_servers.artemis_server show HttpArtemisServer DeviceEntry EventEntry User
import .artemis_server_test_base
import artemis.shared.server_config show ServerConfigHttpToit
import .utils

class ToitHttpBackdoor implements ArtemisServerBackdoor:
  server_/HttpArtemisServer

  constructor .server_:

  fetch_device_information --hardware_id/string -> List:
    entry/DeviceEntry := server_.devices[hardware_id]
    return [
      entry.id,
      entry.organization_id,
      entry.alias,
    ]

  has_event --hardware_id/string --type/string -> bool:
    server_.events.do: | entry/EventEntry |
      if entry.device_id == hardware_id and
          entry.data is Map and (entry.data.get "type") == type:
        return true
    return false

main:
  with_http_artemis_server: | server/HttpArtemisServer server_config/ServerConfigHttpToit |
    server.add_organization TEST_ORGANIZATION_UUID TEST_ORGANIZATION_NAME
    backdoor/ToitHttpBackdoor := ToitHttpBackdoor server
    run_test server_config backdoor  --authenticate=:
      server.create_user --name=TEST_EXAMPLE_COM_NAME
          --email=TEST_EXAMPLE_COM_EMAIL
          --id=TEST_EXAMPLE_COM_UUID
          --set_current
      server.create_user --name=DEMO_EXAMPLE_COM_NAME
          --email=DEMO_EXAMPLE_COM_EMAIL
          --id=DEMO_EXAMPLE_COM_UUID
