// Copyright (C) 2022 Toitware ApS.

import .brokers

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.broker as cli_broker
import artemis.service
import artemis.service.device show Device
import artemis.shared.broker_config show BrokerConfig
import .utils

main:
  with_tmp_directory: | tmp_dir |
    config_file := "$tmp_dir/config"
    config := config.read_config_file config_file --init=: it
    cache_dir := "$tmp_dir/CACHE"
    cache := cache.Cache --app_name="artemis-test" --path=cache_dir

    device_id := "test-device"
    device := Device --id=device_id --firmware="foo"
    with_http_broker: | broker_config/BrokerConfig |
      artemis_task := task::
        service.run_artemis device broker_config --no-start_ntp

      cli_broker.add_broker_to_config config broker_config

      cli.main --config=config --cache=cache [
        "set-max-offline",
        "--broker", broker_config.name,
        "--broker.artemis", broker_config.name,
        "--device=$device_id", "3"
      ]

      with_timeout --ms=1_000:
        counter := 0
        while true:
          if device.max_offline == (Duration --s=3): break
          sleep --ms=counter
          counter++

      artemis_task.cancel
