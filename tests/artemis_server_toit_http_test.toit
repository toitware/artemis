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

  install_service_images images/List -> none:
    image_binaries := {:}
    sdk_service_versions := []
    images.do: | entry/Map |
      sdk_service_versions.add {
        "sdk_version": entry["sdk_version"],
        "service_version": entry["service_version"],
        "image": entry["image"],
      }
      image_binaries[entry["image"]] = entry["content"]

    server_.sdk_service_versions = sdk_service_versions
    server_.image_binaries = image_binaries

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
