// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import ..artemis
import ..config
import ..cache
import ..ui
import ..server_config

with_artemis parsed/cli.Parsed config/Config cache/Cache ui/Ui [block]:
  broker_config := get_server_from_config config CONFIG_BROKER_DEFAULT_KEY
  artemis_config := get_server_from_config config CONFIG_ARTEMIS_DEFAULT_KEY

  artemis := Artemis --config=config --cache=cache --ui=ui \
      --broker_config=broker_config --artemis_config=artemis_config

  try:
    block.call artemis
  finally:
    artemis.close
