// Copyright (C) 2022 Toitware ApS. All rights reserved.

import expect show *
import log
import mqtt.broker
import artemis.cli.artemis show Artemis
import artemis.service.synchronize show SynchronizeJob
import artemis.service.applications show ApplicationManager
import artemis.service.mediator_service as mediator
import artemis.service.scheduler show Scheduler
import artemis.cli.mediator_cli as mediator
import artemis.shared.device show Device

import .mediators

main args:
  with_mediators args: | logger name mediator_cli mediator_service |
    run_test logger name mediator_cli mediator_service

run_test
    logger/log.Logger
    mediator_name/string
    mediator_cli/mediator.MediatorCli
    mediator_service/mediator.MediatorService:
  DEVICE_NAME ::= "test-device-$random"

  device := Device DEVICE_NAME
  artemis := Artemis mediator_cli
  scheduler := Scheduler logger
  applications := ApplicationManager logger scheduler
  job := SynchronizeJob logger device applications mediator_service

  task:: job.run
  expect_null (job.config_.get "max-offline")
  artemis.config_set_max_offline --device_id=DEVICE_NAME --max_offline_seconds=10
  sleep --ms=500
  expect_equals 10 (job.config_["max-offline"])
