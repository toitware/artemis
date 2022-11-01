// Copyright (C) 2022 Toitware ApS. All rights reserved.

import binary show LITTLE_ENDIAN
import bytes show Buffer Reader
import expect show *
import reader show BufferedReader

import artemis.cli.utils.binary_diff show *
import artemis.shared.utils.patch show *

main:
  [true, false].do: | fast |
    one_way --fast=fast
    round_trip --fast=fast
        (URFAUST + FAUST1).to_byte_array
        (FAUST1 + URFAUST).to_byte_array
    round_trip --fast=fast
        MOBY_15.to_byte_array
        MOBY_2705.to_byte_array
    round_trip --fast=fast
        MOBY_2705.to_byte_array
        MOBY_15.to_byte_array
  MOBY_2705_ALIGNED ::= MOBY_2705[..MOBY_2705.size & ~3]
  MOBY_15_ALLIGNED ::= MOBY_15[..MOBY_15.size & ~3]
  literal_round_trip
      MOBY_2705_ALIGNED.to_byte_array
  literal_round_trip
      MOBY_2705.to_byte_array
  literal_round_trip
      MOBY_15.to_byte_array
  literal_round_trip
      ByteArray 512
  4.repeat:
    literal_round_trip
        (ByteArray 90 + it) + MOBY_2705.to_byte_array
  literal_round_trip
      MOBY_15.to_byte_array + (ByteArray 87) + MOBY_2705.to_byte_array
  4.repeat:
    literal_round_trip
        (ByteArray 87) + MOBY_2705.to_byte_array + (ByteArray 87 + it)
  literal_round_trip
      (ByteArray 87 --filler=42) + MOBY_2705.to_byte_array + (ByteArray 87 --filler=91)

  odd_size_test

one_way --fast/bool -> none:
  zeros := ByteArray 32
  writer := Buffer

  old := OldData zeros 0 0

  diff
      old
      zeros      // New bytes.
      writer
      zeros.size // Total new bytes size.
      --fast=fast
      --with_header=false
      --with_footer=false
      --with_checksums=false

  result := writer.bytes
  print result

  now := "Now is the time for all good men".to_byte_array
  to  := "to come to the aid of the party.".to_byte_array
  writer = Buffer
  diff
      OldData now 0 0
      to
      writer
      to.size
      --fast=fast
      --with_header=false
      --with_footer=false
      --with_checksums=false

  result = writer.bytes
  print result.size

  writer = Buffer
  diff
      OldData now 0 0
      to
      writer
      to.size
      --fast=fast
      --with_header=false
      --with_footer=false
      --with_checksums=false

  result = writer.bytes
  print result.size
  print result

  print "**** Welcome to Denmark ****"

  now = "Welcome to Aarhus, hope you like".to_byte_array
  to  = "Welcome to Copenhagen, hope you ".to_byte_array
  writer = Buffer
  diff
      OldData now 0 0
      to
      writer
      to.size
      --fast=fast
      --with_header=false
      --with_footer=false
      --with_checksums=false

  result = writer.bytes
  print result.size
  print result

  print "**** Faust *****"

  now = URFAUST.to_byte_array
  to  = FAUST1.to_byte_array

  old_data := OldData now 0 0

  ur_sections := Section.get_sections old_data 16

  writer = Buffer
  diff
      OldData now 0 0
      to
      writer
      to.size
      --fast=fast
      --with_header=false
      --with_footer=false
      --with_checksums=false
  result = writer.bytes

  expected_slow := #[
      0x7f, 0x52, 0x00, 0xfb, 0x0a, 0x48, 0x61, 0x62, 0x65,
      0x20, 0x6e, 0x75, 0x6e, 0x2c, 0x20, 0x61, 0x63, 0x68, 0x21,
      0x20, 0x50, 0x68, 0x69, 0x6c, 0x6f, 0x73, 0x6f, 0x70, 0x68,
      0x69, 0x65, 0x2c, 0x0a, 0x4a, 0x75, 0x72, 0x69, 0x73, 0x74,
      0x65, 0x72, 0x65, 0x69, 0x20, 0x75, 0x6e, 0x64, 0x20, 0x4d,
      0x65, 0x64, 0x69, 0x7a, 0x69, 0x6e, 0x2c, 0x0a, 0x55, 0x6e,
      0x64, 0x20, 0x6c, 0x65, 0x69, 0x64, 0x65, 0x72, 0x20, 0x61,
      0x75, 0x63, 0x68, 0x20, 0xef, 0x00, 0x00, 0x4a, 0x7c, 0x3e,
      0x99, 0x5c, 0x9d, 0x3e, 0x0b, 0x3f, 0x9f, 0x99, 0x3e, 0xc1,
      0x70, 0xe7, 0xd9, 0x5b, 0x48, 0x10, 0x99, 0x5b, 0x70, 0xef,
      0x1a, 0x1b, 0xbf, 0x9f, 0x5f, 0x18, 0x3f, 0x43, 0xe0, 0x85,
      0x93, 0xf5, 0xef, 0xe0, 0xed, 0x7e, 0x70, 0xe7, 0xc3, 0xec,
      0x39, 0x35, 0x85, 0x9d, 0xa5, 0xcd, 0xd1, 0x95, 0xc8, 0xb0,
      0x81, 0xa1, 0x95, 0xa7, 0x0e, 0x7d, 0x94, 0x81, 0x11, 0xbd,
      0xad, 0xd3, 0xf9, 0xf9, 0xf4, 0x3f, 0xf5, 0xf1, 0xcf, 0xe1,
      0x97, 0xf1, 0x8f, 0xa2, 0x0e, 0x28, 0x0f, 0xe7, 0xcf, 0x89,
      0x36, 0x4f, 0x86, 0x5f, 0xc5, 0xf9, 0xc3, 0x9f, 0x7c, 0x4f,
      0x82, 0x17, 0xd0, 0x3f, 0xd7, 0x0f, 0x86, 0x97, 0x0f, 0xd7,
      0x0f, 0xa2, 0xc0, 0xa4, 0x4f, 0x23, 0x17, 0xec, 0x11, 0x95,
      0xb8, 0xb0, 0x81, 0x35, 0x85, 0x9d, 0xa5, 0xcd, 0xd1, 0x94,
      0xfd, 0x7c, 0xf8, 0x3b, 0x7d, 0x01, 0xf8, 0x65, 0xfc, 0x7a,
      0xf8, 0x65, 0xfc, 0x71, 0xfa, 0x20, 0xe2, 0x80, 0xf8, 0x93,
      0xfe, 0x7d, 0x7c, 0x3e, 0x19, 0x7f, 0x1e, 0xfe, 0x19, 0x7f,
      0x1e, 0x7e, 0x14, 0x9e, 0xbe, 0x19, 0x7f, 0x1f, 0x13, 0xe1,
      0x97, 0xf1, 0xc3, 0xe0, 0xb3, 0xf1, 0xf1, 0xdb, 0xe0, 0xb9,
      0xf1, 0x9b, 0xe0, 0xb3, 0xf1, 0xf1, 0xc7, 0xe0, 0xed, 0x83,
      0xe9, 0x8d, 0xa1, 0xd3, 0xe1, 0x97, 0xf9, 0xf9, 0xf1, 0x7e,
      0x08, 0x7f, 0x1f, 0x44, 0x3f, 0x5f, 0x19, 0x7e, 0x88, 0x1d,
      0xf0, 0xfe, 0x2f, 0x19, 0x3e, 0x0e, 0xd3, 0xe7, 0x0e, 0x7d,
      0xf1, 0x9b, 0xec, 0x3f, 0x0e, 0x7c, 0x29, 0x69, 0xd4, 0x81,
      0xcd, 0x85, 0x9d, 0x95, 0xb8, 0x81, 0x89, 0xc9, 0x85, 0xd5,
      0x8d, 0xa1, 0x94, 0xb0, 0x81, 0xdf, 0xf9, 0xed, 0xd7, 0xeb,
      0x0e, 0x7c, 0xef, 0xf1, 0x3e, 0x70, 0xe7, 0xdf, 0x18, 0x3e,
      0x12, 0x5f, 0x1c, 0xbe, 0x9a, 0x5c, 0x9a, 0xfe, 0x59, 0x5b,
      0xbf, 0xa0, 0xdb, 0xec, 0xa5, 0xd0, 0x81, 0xd5, 0xb9, 0x90,
      0x81, 0x4d, 0x85, 0xb5, 0x95, 0xb8, 0xb0, 0x29, 0x55, 0xb9,
      0x90, 0x81, 0xd1, 0xd4, 0x81, 0xb9, 0xa5, 0x8d, 0xa1, 0xd0,
      0x81, 0xb5, 0x95, 0xa1, 0xc8, 0x81, 0xa5, 0xb8, 0x81, 0x5d,
      0xbd, 0xc9, 0xd1, 0x95, 0xb8, 0x81, 0xad, 0xc9, 0x85, 0xb5,
      0x95, 0xb8, 0xbb, 0xfa, 0x00,
  ]

  if not fast:
    expect_bytes_equal expected_slow result

  now = (URFAUST + FAUST1).to_byte_array
  to  = (FAUST1 + URFAUST).to_byte_array

  old_data = OldData now 0 0

  writer = Buffer
  diff
      OldData now 0 0
      to
      writer
      to.size
      --fast=fast
      --with_header=false
      --with_footer=false
      --with_checksums=false
  result = writer.bytes

  // Just swapping the order of the bytes is quite compact.
  expected := #[
      0x7f, 0x52, 0x00, 0xef, 0x00, 0x04, 0x86, 0x7e, 0x03,
      0x96, 0xf8, 0x48, 0xef, 0x00, 0x00, 0x01, 0x7e, 0x03, 0x86]

  if not fast:
    expect_bytes_equal expected result

  writer = Buffer
  diff
      OldData now 0 0
      to
      writer
      to.size
      --fast=fast
      --with_header=true
      --with_footer=true
      --with_checksums=true
  result = writer.bytes

  // A bit less compact with headers, footers and checksums.
  expected = #[
      0x7f, 0x4d, 0x20, 0x70, 0x17, 0xd1, 0xff, 0x7f, 0xee, 0x10, 0x09, 0x1b, 0x7f, 0xd3,
      0x41, 0x30, 0x00, 0x00, 0x00, 0x00, 0x09, 0x1b, 0x66, 0xa5, 0x72, 0x66, 0x3e, 0x85, 0x47, 0xce,
      0x09, 0x20, 0x17, 0xb3, 0x06, 0x46, 0x1f, 0xf0, 0x26, 0x2e, 0xb3, 0xe1, 0xca, 0xdc, 0x40, 0x58,
      0xd8, 0x01, 0xe6, 0x19, 0x71, 0xd7, 0xfb, 0xd4, 0xef, 0x00, 0x04, 0x86, 0x7e, 0x03, 0x96, 0xf8,
      0x48, 0xef, 0x00, 0x00, 0x01, 0x7e, 0x03, 0x86, 0x7f, 0x45, 0x00
  ]

  if not fast:
    expect_bytes_equal expected result

  List.chunk_up 0 result.size 16: | from to size |
    print result[from..to]

class TestWriter implements PatchObserver:
  size /int? := null
  writer /Buffer := Buffer

  on_write data from/int=0 to/int=data.size:
    writer.write data[from..to]

  on_size size/int: this.size = size

  on_new_checksum checksum/ByteArray:

  on_checkpoint patch_position/int:

round_trip now/ByteArray to/ByteArray --fast/bool -> none:
  old_data := OldData now 0 0

  writer := Buffer
  diff
      OldData now 0 0
      to
      writer
      to.size
      --fast=fast
      --with_header=true
      --with_footer=true
      --with_checksums=false
  result := writer.bytes

  test_writer := TestWriter

  patcher := Patcher
      BufferedReader (Reader result)
      now

  patcher.patch test_writer

  expect_equals to.size test_writer.size
  expect_equals to test_writer.writer.bytes

literal_round_trip now/ByteArray -> none:
  writer := Buffer
  literal_block now writer --total_new_bytes=now.size --with_footer=true

  result := writer.bytes

  test_writer := TestWriter

  patcher := Patcher
      BufferedReader (Reader result)
      #[]

  patcher.patch test_writer

  round_tripped := test_writer.writer.bytes
  expect_equals now.size round_tripped.size
  expect_equals now test_writer.writer.bytes

odd_size_test:
  4.repeat: | old_extra |
    4.repeat: | new_extra |
      old := ByteArray 124 + old_extra: it
      new := ByteArray 124 + new_extra: it
      for i := 0; i < old.size - 4; i += 4:
        LITTLE_ENDIAN.put_uint32 old i i
        LITTLE_ENDIAN.put_uint32 new i i
      for i := 0; i < new.size - 4; i += 8:
        LITTLE_ENDIAN.put_uint32 new i i + 451

      [true, false].do: | fast |
        [true, false].do: | checksums |
          writer := Buffer
          diff
              OldData old 0 0
              new
              writer
              new.size
              --fast=fast
              --with_header=false
              --with_footer=true
              --with_checksums=checksums
          result := writer.bytes

          test_writer := TestWriter

          patcher := Patcher
              BufferedReader (Reader result)
              old

          patcher.patch test_writer

          round_tripped := test_writer.writer.bytes

          expect_equals new.size round_tripped.size
          expect_equals new test_writer.writer.bytes

MOBY_2705 ::= """\
Call me Ishmael. Some years ago—never mind how long precisely—having
little or no money in my purse, and nothing particular to interest me
on shore, I thought I would sail about a little and see the watery part
of the world. It is a way I have of driving off the spleen and
regulating the circulation. Whenever I find myself growing grim about
the mouth; whenever it is a damp, drizzly November in my soul; whenever
I find myself involuntarily pausing before coffin warehouses, and
bringing up the rear of every funeral I meet; and especially whenever
my hypos get such an upper hand of me, that it requires a strong moral
principle to prevent me from deliberately stepping into the street, and
methodically knocking people’s hats off—then, I account it high time to
get to sea as soon as I can. This is my substitute for pistol and ball.
With a philosophical flourish Cato throws himself upon his sword; I
quietly take to the ship. There is nothing surprising in this. If they
but knew it, almost all men in their degree, some time or other,
cherish very nearly the same feelings towards the ocean with me.

There now is your insular city of the Manhattoes, belted round by
wharves as Indian isles by coral reefs—commerce surrounds it with her
surf. Right and left, the streets take you waterward. Its extreme
downtown is the battery, where that noble mole is washed by waves, and
cooled by breezes, which a few hours previous were out of sight of
land. Look at the crowds of water-gazers there.

Circumambulate the city of a dreamy Sabbath afternoon. Go from Corlears
Hook to Coenties Slip, and from thence, by Whitehall, northward. What
do you see?—Posted like silent sentinels all around the town, stand
thousands upon thousands of mortal men fixed in ocean reveries. Some
leaning against the spiles; some seated upon the pier-heads; some
looking over the bulwarks of ships from China; some high aloft in the
rigging, as if striving to get a still better seaward peep. But these
are all landsmen; of week days pent up in lath and plaster—tied to
counters, nailed to benches, clinched to desks. How then is this? Are
the green fields gone? What do they here?

But look! here come more crowds, pacing straight for the water, and
seemingly bound for a dive. Strange! Nothing will content them but the
extremest limit of the land; loitering under the shady lee of yonder
warehouses will not suffice. No. They must get just as nigh the water
as they possibly can without falling in. And there they stand—miles of
them—leagues. Inlanders all, they come from lanes and alleys, streets
and avenues—north, east, south, and west. Yet here they all unite. Tell
me, does the magnetic virtue of the needles of the compasses of all
those ships attract them thither?

Once more. Say you are in the country; in some high land of lakes. Take
almost any path you please, and ten to one it carries you down in a
dale, and leaves you there by a pool in the stream. There is magic in
it. Let the most absent-minded of men be plunged in his deepest
reveries—stand that man on his legs, set his feet a-going, and he will
infallibly lead you to water, if water there be in all that region.
Should you ever be athirst in the great American desert, try this
experiment, if your caravan happen to be supplied with a metaphysical
professor. Yes, as every one knows, meditation and water are wedded for
ever.

But here is an artist. He desires to paint you the dreamiest, shadiest,
quietest, most enchanting bit of romantic landscape in all the valley
of the Saco. What is the chief element he employs? There stand his
trees, each with a hollow trunk, as if a hermit and a crucifix were
within; and here sleeps his meadow, and there sleep his cattle; and up
from yonder cottage goes a sleepy smoke. Deep into distant woodlands
winds a mazy way, reaching to overlapping spurs of mountains bathed in
their hill-side blue. But though the picture lies thus tranced, and
though this pine-tree shakes down its sighs like leaves upon this
shepherd’s head, yet all were vain, unless the shepherd’s eye were
fixed upon the magic stream before him. Go visit the Prairies in June,
when for scores on scores of miles you wade knee-deep among
Tiger-lilies—what is the one charm wanting?—Water—there is not a drop
of water there! Were Niagara but a cataract of sand, would you travel
your thousand miles to see it? Why did the poor poet of Tennessee, upon
suddenly receiving two handfuls of silver, deliberate whether to buy
him a coat, which he sadly needed, or invest his money in a pedestrian
trip to Rockaway Beach? Why is almost every robust healthy boy with a
robust healthy soul in him, at some time or other crazy to go to sea?
Why upon your first voyage as a passenger, did you yourself feel such a
mystical vibration, when first told that you and your ship were now out
of sight of land? Why did the old Persians hold the sea holy? Why did
the Greeks give it a separate deity, and own brother of Jove? Surely
all this is not without meaning. And still deeper the meaning of that
story of Narcissus, who because he could not grasp the tormenting, mild
image he saw in the fountain, plunged into it and was drowned. But that
same image, we ourselves see in all rivers and oceans. It is the image
of the ungraspable phantom of life; and this is the key to it all.

Now, when I say that I am in the habit of going to sea whenever I begin
to grow hazy about the eyes, and begin to be over conscious of my
lungs, I do not mean to have it inferred that I ever go to sea as a
passenger. For to go as a passenger you must needs have a purse, and a
purse is but a rag unless you have something in it. Besides, passengers
get sea-sick—grow quarrelsome—don’t sleep of nights—do not enjoy
themselves much, as a general thing;—no, I never go as a passenger;
nor, though I am something of a salt, do I ever go to sea as a
Commodore, or a Captain, or a Cook. I abandon the glory and distinction
of such offices to those who like them. For my part, I abominate all
honorable respectable toils, trials, and tribulations of every kind
whatsoever. It is quite as much as I can do to take care of myself,
without taking care of ships, barques, brigs, schooners, and what not.
And as for going as cook,—though I confess there is considerable glory
in that, a cook being a sort of officer on ship-board—yet, somehow, I
never fancied broiling fowls;—though once broiled, judiciously
buttered, and judgmatically salted and peppered, there is no one who
will speak more respectfully, not to say reverentially, of a broiled
fowl than I will. It is out of the idolatrous dotings of the old
Egyptians upon broiled ibis and roasted river horse, that you see the
mummies of those creatures in their huge bake-houses the pyramids.

No, when I go to sea, I go as a simple sailor, right before the mast,
plumb down into the forecastle, aloft there to the royal mast-head.
True, they rather order me about some, and make me jump from spar to
spar, like a grasshopper in a May meadow. And at first, this sort of
thing is unpleasant enough. It touches one’s sense of honor,
particularly if you come of an old established family in the land, the
Van Rensselaers, or Randolphs, or Hardicanutes. And more than all, if
just previous to putting your hand into the tar-pot, you have been
lording it as a country schoolmaster, making the tallest boys stand in
awe of you. The transition is a keen one, I assure you, from a
schoolmaster to a sailor, and requires a strong decoction of Seneca and
the Stoics to enable you to grin and bear it. But even this wears off
in time.

What of it, if some old hunks of a sea-captain orders me to get a broom
and sweep down the decks? What does that indignity amount to, weighed,
I mean, in the scales of the New Testament? Do you think the archangel
Gabriel thinks anything the less of me, because I promptly and
respectfully obey that old hunks in that particular instance? Who ain’t
a slave? Tell me that. Well, then, however the old sea-captains may
order me about—however they may thump and punch me about, I have the
satisfaction of knowing that it is all right; that everybody else is
one way or other served in much the same way—either in a physical or
metaphysical point of view, that is; and so the universal thump is
passed round, and all hands should rub each other’s shoulder-blades,
and be content.

Again, I always go to sea as a sailor, because they make a point of
paying me for my trouble, whereas they never pay passengers a single
penny that I ever heard of. On the contrary, passengers themselves must
pay. And there is all the difference in the world between paying and
being paid. The act of paying is perhaps the most uncomfortable
infliction that the two orchard thieves entailed upon us. But _being
paid_,—what will compare with it? The urbane activity with which a man
receives money is really marvellous, considering that we so earnestly
believe money to be the root of all earthly ills, and that on no
account can a monied man enter heaven. Ah! how cheerfully we consign
ourselves to perdition!

Finally, I always go to sea as a sailor, because of the wholesome
exercise and pure air of the fore-castle deck. For as in this world,
head winds are far more prevalent than winds from astern (that is, if
you never violate the Pythagorean maxim), so for the most part the
Commodore on the quarter-deck gets his atmosphere at second hand from
the sailors on the forecastle. He thinks he breathes it first; but not
so. In much the same way do the commonalty lead their leaders in many
other things, at the same time that the leaders little suspect it. But
wherefore it was that after having repeatedly smelt the sea as a
merchant sailor, I should now take it into my head to go on a whaling
voyage; this the invisible police officer of the Fates, who has the
constant surveillance of me, and secretly dogs me, and influences me in
some unaccountable way—he can better answer than any one else. And,
doubtless, my going on this whaling voyage, formed part of the grand
programme of Providence that was drawn up a long time ago. It came in
as a sort of brief interlude and solo between more extensive
performances. I take it that this part of the bill must have run
something like this:"""

MOBY_15 ::= """\
Call me Ishmael. Some years ago—never mind how long precisely—having
little or no money in my purse, and nothing particular to interest me
on shore, I thought I would sail about a little and see the watery part
of the world. It is a way I have of driving off the spleen, and
regulating the circulation. Whenever I find myself growing grim about
the mouth; whenever it is a damp, drizzly November in my soul; whenever
I find myself involuntarily pausing before coffin warehouses, and
bringing up the rear of every funeral I meet; and especially whenever
my hypos get such an upper hand of me, that it requires a strong moral
principle to prevent me from deliberately stepping into the street, and
methodically knocking people’s hats off—then, I account it high time to
get to sea as soon as I can. This is my substitute for pistol and ball.
With a philosophical flourish Cato throws himself upon his sword; I
quietly take to the ship. There is nothing surprising in this. If they
but knew it, almost all men in their degree, some time or other,
cherish very nearly the same feelings towards the ocean with me.

There now is your insular city of the Manhattoes, belted round by
wharves as Indian isles by coral reefs—commerce surrounds it with her
surf. Right and left, the streets take you waterward. Its extreme
down-town is the battery, where that noble mole is washed by waves, and
cooled by breezes, which a few hours previous were out of sight of
land. Look at the crowds of water-gazers there.

Circumambulate the city of a dreamy Sabbath afternoon. Go from Corlears
Hook to Coenties Slip, and from thence, by Whitehall northward. What do
you see?—Posted like silent sentinels all around the town, stand
thousands upon thousands of mortal men fixed in ocean reveries. Some
leaning against the spiles; some seated upon the pier-heads; some
looking over the bulwarks of ships from China; some high aloft in the
rigging, as if striving to get a still better seaward peep. But these
are all landsmen; of week days pent up in lath and plaster—tied to
counters, nailed to benches, clinched to desks. How then is this? Are
the green fields gone? What do they here?

But look! here come more crowds, pacing straight for the water, and
seemingly bound for a dive. Strange! Nothing will content them but the
extremest limit of the land; loitering under the shady lee of yonder
warehouses will not suffice. No. They must get just as nigh the water
as they possibly can without falling in. And there they stand—miles of
them—leagues. Inlanders all, they come from lanes and alleys, streets
and avenues,—north, east, south, and west. Yet here they all unite.
Tell me, does the magnetic virtue of the needles of the compasses of
all those ships attract them thither?

Once more. Say, you are in the country; in some high land of lakes.
Take almost any path you please, and ten to one it carries you down in
a dale, and leaves you there by a pool in the stream. There is magic in
it. Let the most absent-minded of men be plunged in his deepest
reveries—stand that man on his legs, set his feet a-going, and he will
infallibly lead you to water, if water there be in all that region.
Should you ever be athirst in the great American desert, try this
experiment, if your caravan happen to be supplied with a metaphysical
professor. Yes, as every one knows, meditation and water are wedded for
ever.

But here is an artist. He desires to paint you the dreamiest, shadiest,
quietest, most enchanting bit of romantic landscape in all the valley
of the Saco. What is the chief element he employs? There stand his
trees, each with a hollow trunk, as if a hermit and a crucifix were
within; and here sleeps his meadow, and there sleep his cattle; and up
from yonder cottage goes a sleepy smoke. Deep into distant woodlands
winds a mazy way, reaching to overlapping spurs of mountains bathed in
their hill-side blue. But though the picture lies thus tranced, and
though this pine-tree shakes down its sighs like leaves upon this
shepherd’s head, yet all were vain, unless the shepherd’s eye were
fixed upon the magic stream before him. Go visit the Prairies in June,
when for scores on scores of miles you wade knee-deep among
Tiger-lilies—what is the one charm wanting?—Water—there is not a drop
of water there! Were Niagara but a cataract of sand, would you travel
your thousand miles to see it? Why did the poor poet of Tennessee, upon
suddenly receiving two handfuls of silver, deliberate whether to buy
him a coat, which he sadly needed, or invest his money in a pedestrian
trip to Rockaway Beach? Why is almost every robust healthy boy with a
robust healthy soul in him, at some time or other crazy to go to sea?
Why upon your first voyage as a passenger, did you yourself feel such a
mystical vibration, when first told that you and your ship were now out
of sight of land? Why did the old Persians hold the sea holy? Why did
the Greeks give it a separate deity, and own brother of Jove? Surely
all this is not without meaning. And still deeper the meaning of that
story of Narcissus, who because he could not grasp the tormenting, mild
image he saw in the fountain, plunged into it and was drowned. But that
same image, we ourselves see in all rivers and oceans. It is the image
of the ungraspable phantom of life; and this is the key to it all.

Now, when I say that I am in the habit of going to sea whenever I begin
to grow hazy about the eyes, and begin to be over conscious of my
lungs, I do not mean to have it inferred that I ever go to sea as a
passenger. For to go as a passenger you must needs have a purse, and a
purse is but a rag unless you have something in it. Besides, passengers
get sea-sick—grow quarrelsome—don’t sleep of nights—do not enjoy
themselves much, as a general thing;—no, I never go as a passenger;
nor, though I am something of a salt, do I ever go to sea as a
Commodore, or a Captain, or a Cook. I abandon the glory and distinction
of such offices to those who like them. For my part, I abominate all
honorable respectable toils, trials, and tribulations of every kind
whatsoever. It is quite as much as I can do to take care of myself,
without taking care of ships, barques, brigs, schooners, and what not.
And as for going as cook,—though I confess there is considerable glory
in that, a cook being a sort of officer on ship-board—yet, somehow, I
never fancied broiling fowls;—though once broiled, judiciously
buttered, and judgmatically salted and peppered, there is no one who
will speak more respectfully, not to say reverentially, of a broiled
fowl than I will. It is out of the idolatrous dotings of the old
Egyptians upon broiled ibis and roasted river horse, that you see the
mummies of those creatures in their huge bake-houses the pyramids.

No, when I go to sea, I go as a simple sailor, right before the mast,
plumb down into the forecastle, aloft there to the royal mast-head.
True, they rather order me about some, and make me jump from spar to
spar, like a grasshopper in a May meadow. And at first, this sort of
thing is unpleasant enough. It touches one’s sense of honor,
particularly if you come of an old established family in the land, the
van Rensselaers, or Randolphs, or Hardicanutes. And more than all, if
just previous to putting your hand into the tar-pot, you have been
lording it as a country schoolmaster, making the tallest boys stand in
awe of you. The transition is a keen one, I assure you, from the
schoolmaster to a sailor, and requires a strong decoction of Seneca and
the Stoics to enable you to grin and bear it. But even this wears off
in time.

What of it, if some old hunks of a sea-captain orders me to get a broom
and sweep down the decks? What does that indignity amount to, weighed,
I mean, in the scales of the New Testament? Do you think the archangel
Gabriel thinks anything the less of me, because I promptly and
respectfully obey that old hunks in that particular instance? Who aint
a slave? Tell me that. Well, then, however the old sea-captains may
order me about—however they may thump and punch me about, I have the
satisfaction of knowing that it is all right; that everybody else is
one way or other served in much the same way—either in a physical or
metaphysical point of view, that is; and so the universal thump is
passed round, and all hands should rub each other’s shoulder-blades,
and be content.

Again, I always go to sea as a sailor, because they make a point of
paying me for my trouble, whereas they never pay passengers a single
penny that I ever heard of. On the contrary, passengers themselves must
pay. And there is all the difference in the world between paying and
being paid. The act of paying is perhaps the most uncomfortable
infliction that the two orchard thieves entailed upon us. But _being
paid_,—what will compare with it? The urbane activity with which a man
receives money is really marvellous, considering that we so earnestly
believe money to be the root of all earthly ills, and that on no
account can a monied man enter heaven. Ah! how cheerfully we consign
ourselves to perdition!

Finally, I always go to sea as a sailor, because of the wholesome
exercise and pure air of the forecastle deck. For as in this world,
head winds are far more prevalent than winds from astern (that is, if
you never violate the Pythagorean maxim), so for the most part the
Commodore on the quarter-deck gets his atmosphere at second hand from
the sailors on the forecastle. He thinks he breathes it first; but not
so. In much the same way do the commonalty lead their leaders in many
other things, at the same time that the leaders little suspect it. But
wherefore it was that after having repeatedly smelt the sea as a
merchant sailor, I should now take it into my head to go on a whaling
voyage; this the invisible police officer of the Fates, who has the
constant surveillance of me, and secretly dogs me, and influences me in
some unaccountable way—he can better answer than any one else. And,
doubtless, my going on this whaling voyage, formed part of the grand
programme of Providence that was drawn up a long time ago. It came in
as a sort of brief interlude and solo between more extensive
performances. I take it that this part of the bill must have run
something like this:"""

URFAUST ::= """\
Hab nun, ach! die Philosophey,
Medizin und Juristerey
Und leider auch die Theologie
Durchaus studirt mit heisser Müh.
Da steh ich nun, ich armer Thor,
Und binn so klug als wie zuvor.
Heisse Docktor und Professor gar
Und ziehe schon an die zehen Jahr
Herauf, herab und queer und krumm
Meine Schüler an der Nas herum
Und seh, dass wir nichts wissen können:
Das will mir schier das Herz verbrennen.
Zwar binn ich gescheuter als alle die Laffen
Docktors, Professors, Schreiber und Pfaffen,
Mich plagen keine Skrupel noch Zweifel,
Fürcht mich weder vor Höll noch Teufel.
Dafür ist mir auch all Freud entrissen,
Bild mir nicht ein, was rechts zu wissen,
Bild mir nicht ein, ich könnt was lehren
Die Menschen zu bessern und zu bekehren,
Auch hab ich weder Gut noch Geld
Noch Ehr und Herrlichkeit der Welt:
Es mögt kein Hund so länger leben
Drum hab ich mich der Magie ergeben,
Ob mir durch Geistes Krafft und Mund
Nicht manch Geheimniss werde kund,
Dass ich nicht mehr mit saurem Schweis
Rede von dem, was ich nicht weis,
Dass ich erkenne, was die Welt
Im innersten zusammenhält,
Schau alle Würckungskrafft und Saamen
Und tuh nicht mehr in Worten kramen."""

FAUST1 ::= """\
Habe nun, ach! Philosophie,
Juristerei und Medizin,
Und leider auch Theologie
Durchaus studiert, mit heißem Bemühn.
Da steh ich nun, ich armer Tor!
Und bin so klug als wie zuvor;
Heiße Magister, heiße Doktor gar
Und ziehe schon an die zehen Jahr
Herauf, herab und quer und krumm
Meine Schüler an der Nase herum –
Und sehe, daß wir nichts wissen können!
Das will mir schier das Herz verbrennen.
Zwar bin ich gescheiter als all die Laffen,
Doktoren, Magister, Schreiber und Pfaffen;
Mich plagen keine Skrupel noch Zweifel,
Fürchte mich weder vor Hölle noch Teufel –
Dafür ist mir auch alle Freud entrissen,
Bilde mir nicht ein, was Rechts zu wissen,
Bilde mir nicht ein, ich könnte was lehren,
Die Menschen zu bessern und zu bekehren.
Auch hab ich weder Gut noch Geld,
Noch Ehr und Herrlichkeit der Welt;
Es möchte kein Hund so länger leben!
Drum hab ich mich der Magie ergeben,
Ob mir durch Geistes Kraft und Mund
Nicht manch Geheimnis würde kund;
Daß ich nicht mehr mit saurem Schweiß
Zu sagen brauche, was ich nicht weiß;
Daß ich erkenne, was die Welt
Im Innersten zusammenhält,
Schau alle Wirkenskraft und Samen,
Und tu nicht mehr in Worten kramen."""
