// Copyright (C) 2023 Toitware ApS. All rights reserved.

import ar show *
import encoding.json
import host.file
import writer show Writer
import reader show Reader

import .artemis
import .device_specification
import .ui
import .utils

/**
An Artemis Firmware is a file that wraps a customized firmware envelope.
In addition to the envelope it also contains helpful information, like
  the specification that was used to create the firmware.
*/
class Afw:
  // Ar files can only have 15 chars for the name.
  static MAGIC_NAME_ ::= "artemis-fw"
  static CUSTOMIZED_ENVELOPE_NAME_ := "customized.env"
  static SPECIFICATION_NAME_ := "spec.json"

  static MAGIC_CONTENT_ ::= "frickin' sharks"

  envelope/ByteArray
  specification_content_/Map  // The JSON map of the specification.

  constructor --.envelope --specification_content/Map:
    specification_content_ = specification_content

  constructor.from_specification --path --artemis/Artemis --ui/Ui:
    specification_content := read_json path
    parsed_specification := parse_device_specification_file path --ui=ui
    with_tmp_directory: | tmp_dir/string |
      customized_path := "$tmp_dir/customized.envelope"
      artemis.customize_envelope
          --output_path=customized_path
          --device_specification=parsed_specification

      envelope := file.read_content customized_path
      return Afw --envelope=envelope --specification_content=specification_content
    unreachable

  static parse path/string --ui/Ui -> Afw:
    read_file path --ui=ui: | reader/Reader |
      envelope/ByteArray? := null
      specification_content/Map? := null

      verified_magic := false

      ar_reader := ArReader reader
      file := ar_reader.next
      if file.name != CUSTOMIZED_ENVELOPE_NAME_ or file.content != MAGIC_CONTENT_.to_byte_array:
        ui.abort "The file at '$path' is not a valid Artemis Firmware."
      file = ar_reader.next
      if file.name != CUSTOMIZED_ENVELOPE_NAME_:
        ui.abort "The file at '$path' is not a valid Artemis Firmware."
      envelope = file.content
      file = ar_reader.next
      if file.name != SPECIFICATION_NAME_:
        ui.abort "The file at '$path' is not a valid Artemis Firmware."
      exception := catch:
        specification_content = json.decode file.content
      if exception:
        ui.abort "The file at '$path' is not a valid Artemis Firmware: $exception."
      return Afw --envelope=envelope --specification_content=specification_content
    unreachable

  write path/string --ui/Ui:
    write_file path --ui=ui: | writer/Writer |
      ar_writer := ArWriter writer
      ar_writer.add CUSTOMIZED_ENVELOPE_NAME_ MAGIC_CONTENT_
      ar_writer.add CUSTOMIZED_ENVELOPE_NAME_ envelope
      ar_writer.add SPECIFICATION_NAME_ (json.encode specification_content_)
