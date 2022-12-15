// Copyright (C) 2022 Toitware ApS.

import .brokers

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.service.device show Device
import artemis.shared.server_config show ServerConfig
import .utils

main:
  with_tmp_directory: | tmp_dir |
    config_file := "$tmp_dir/config"
    config := config.read_config_file config_file --init=: it
    cache_dir := "$tmp_dir/CACHE"
    cache := cache.Cache --app_name="artemis-test" --path=cache_dir

    device_id := "test-device"
    device := Device --id=device_id --firmware="foo"
    with_http_broker: | server_config/ServerConfig |
      artemis_task := task::
        service.run_artemis device server_config --no-start_ntp

      cli_server_config.add_server_to_config config server_config

      cli.main --config=config --cache=cache [
        "set-max-offline",
        "--broker", server_config.name,
        "--broker.artemis", server_config.name,
        "--device=$device_id", "3"
      ]

      with_timeout --ms=2_000:
        counter := 0
        while true:
          if device.max_offline == (Duration --s=3): break
          sleep --ms=counter
          counter++

      artemis_task.cancel
