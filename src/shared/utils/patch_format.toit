// Copyright (C) 2022 Toitware ApS. All rights reserved.

// Number of elements in the diff table.
DIFF-TABLE-SIZE ::= 22

// Position that new elements are inserted into the diff table.
DIFF-TABLE-INSERTION ::= 7

// Bit pattern that introduces metadata like the initial magic number.
IGNORABLE-METADATA     ::= 0b0111_1111_1_000_0000
NON-IGNORABLE-METADATA ::= 0b0111_1111_0_000_0000

