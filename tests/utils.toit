// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.directory
import artemis.shared.server_config
import ..tools.http_broker.main as http_broker
import monitor

with_tmp_directory [block]:
  tmp_dir := directory.mkdtemp "/tmp/artemis-test-"
  try:
    block.call tmp_dir
  finally:
    directory.rmdir --recursive tmp_dir

/**
Starts a local http broker and calls the given $block with a
  $server_config.ServerConfig as argument.
*/
with_http_broker [block]:
  broker := http_broker.HttpBroker 0
  port_latch := monitor.Latch
  broker_task := task:: broker.start port_latch

  server_config := server_config.ServerConfigHttpToit "test-server"
      --host="localhost"
      --port=port_latch.get
  try:
    block.call server_config
  finally:
    broker.close
    broker_task.cancel
