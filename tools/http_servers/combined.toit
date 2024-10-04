// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import monitor

import .artemis-server
import .public.broker

main args:
  root-cmd := cli.Command "root"
    --help="""An HTTP-based Artemis server and broker.

      This server keeps data in memory and should thus only be used for
      testing.
      """
    --options=[
      cli.OptionInt "artemis-port"
          --help="The port the Artemis server should listen on.",
      cli.OptionInt "broker-port"
          --help="The port the broker should listen on."
    ]
    --run=:: | parsed/cli.Invocation |
      task::
        artemis := HttpArtemisServer parsed["artemis-port"]
        artemis.start

      broker := HttpBroker parsed["broker-port"]
      broker.start

  root-cmd.run args
