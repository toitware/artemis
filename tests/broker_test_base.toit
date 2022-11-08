// Copyright (C) 2022 Toitware ApS. All rights reserved.

import expect show *
import log
import mqtt.broker
import artemis.cli.artemis show Artemis
import artemis.cli.broker
import artemis.cli.cache show Cache
import artemis.service.synchronize show SynchronizeJob
import artemis.service.applications show ApplicationManager
import artemis.service.broker as broker
import artemis.service.device show Device
import artemis.service.scheduler show Scheduler

import .brokers
import .utils

run_test broker_id/string:
  with_broker broker_id: | logger name broker_cli broker_service |
    run_test logger name broker_cli broker_service

run_test
    logger/log.Logger
    broker_name/string
    broker_cli/broker.BrokerCli
    broker_service/broker.BrokerService:
  DEVICE_NAME ::= "test-device-$random"

  with_tmp_directory: | tmp_dir |
    cache := Cache --app_name="artemis-test" --path=tmp_dir
    device := Device DEVICE_NAME
    artemis := Artemis broker_cli cache
    scheduler := Scheduler logger
    applications := ApplicationManager logger scheduler
    job := SynchronizeJob logger device applications broker_service
      --firmware=""  // TODO(kasper): Should this be something more meaningful?

    task:: job.run
    expect_null (job.config_.get "max-offline")
    artemis.config_set_max_offline --device_id=DEVICE_NAME --max_offline_seconds=10
    with_timeout --ms=15_000:
      while true:
        if job.config_.get "max-offline": break
        sleep --ms=5
    expect_equals 10 (job.config_["max-offline"])
