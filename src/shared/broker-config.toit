// Copyright (C) 2026 Toitware ApS. All rights reserved.

import encoding.base64 as base64-lib
import tls

/**
Configuration used by the Artemis service to connect to its broker.

All URL templates may use `{device-id}` and `{organization-id}`. The goal
  template may additionally use `{wait}`; the image template `{id}` and
  `{word-size}`; the firmware template `{id}` and `{offset}`; and the event
  template `{type}`.
*/
class BrokerConfig:
  static DEFAULT-POLL-INTERVAL ::= Duration --s=20

  fetch-goal-state-url-template/string
  fetch-image-url-template/string
  fetch-firmware-url-template/string
  report-state-url-template/string
  report-event-url-template/string
  root-certificate-ders/List? := ?
  headers/Map?
  poll-interval/Duration := ?

  roots-already-installed_/bool := false

  constructor.from-json config/Map [--der-deserializer]:
    roots/List? := null
    if encoded-roots := config.get "root_certificate_ders64":
      roots = encoded-roots.map: base64-lib.decode it
    else if config.get "root_certificate_ders":
      roots = config["root_certificate_ders"].map: der-deserializer.call it
    return BrokerConfig
        --fetch-goal-state-url-template=config["fetch_goal_state_url_template"]
        --fetch-image-url-template=config["fetch_image_url_template"]
        --fetch-firmware-url-template=config["fetch_firmware_url_template"]
        --report-state-url-template=config["report_state_url_template"]
        --report-event-url-template=config["report_event_url_template"]
        --root-certificate-ders=roots
        --headers=config.get "headers"
        --poll-interval=Duration --us=config["poll_interval"]

  constructor
      --.fetch-goal-state-url-template
      --.fetch-image-url-template
      --.fetch-firmware-url-template
      --.report-state-url-template
      --.report-event-url-template
      --.root-certificate-ders=null
      --.headers=null
      --.poll-interval=DEFAULT-POLL-INTERVAL:

  to-json [--der-serializer] --base64/bool=false -> Map:
    result := {
      "fetch_goal_state_url_template": fetch-goal-state-url-template,
      "fetch_image_url_template": fetch-image-url-template,
      "fetch_firmware_url_template": fetch-firmware-url-template,
      "report_state_url_template": report-state-url-template,
      "report_event_url_template": report-event-url-template,
      "poll_interval": poll-interval.in-us,
    }
    if root-certificate-ders:
      if base64:
        result["root_certificate_ders64"] = root-certificate-ders.map: base64-lib.encode it
      else:
        result["root_certificate_ders"] = root-certificate-ders.map: der-serializer.call it
    if headers: result["headers"] = headers
    return result

  /** Installs the configured root certificates once. */
  install-root-certificates -> none:
    if roots-already-installed_: return
    roots-already-installed_ = true
    if root-certificate-ders:
      root-certificate-ders.do: | der/ByteArray |
        (tls.RootCertificate der).install
