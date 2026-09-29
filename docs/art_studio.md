# V.Smile Art Studio (and the SmartBook)

Neither peripheral is emulated by MAME.  What follows comes from the carts'
controller drivers (disassembled with MAME's debugger `dasm`) and from
running the Art Studio cart in the SoC testbench against the core's tablet
model (`rtl/vsmile_kbd.sv`, pen mode).

## The controller byte stream (both carts)

The Art Studio (Tecknarstudio, Zeichenatelier) and SmartBook (Toy Story 2,
Dora's Got a Puppy) carts share one driver for controller port bytes,
dispatched on the high nibble:

| byte | meaning |
|---|---|
| `5x` | device ID (handshake).  The Smart Keyboard sends `52`; the SmartBook carts check for `53` throughout; the Art Studio cart accepts any `5x` |
| `4x`, then three bytes `00`-`3F` | pen report: `40` pen in range (hovering), `41` tip pressed; the three 6-bit bytes give X = b1 << 4 \| b2 >> 2 (10 bits) and Y = (b2 & 3) << 6 \| b3 (8 bits).  `42` alone: pen out of range (position zeroed; the SmartBook carts store state 2) |
| data bytes without a `4x` header | pairs of signed 6-bit deltas: a relative (mouse) mode |
| `6x 6y` | SmartBook only: one byte from two nibbles, most likely the page |
| `7x` | SmartBook only (device `53`): one more nibble, meaning unknown |
| `80` `C0` `90` `A0` | the joystick's stick, colour and button bytes |
| `B0` | probe answer, as for the joystick |

## Art Studio tablet (implemented)

* Handshake: the device sends its ID three times like the keyboard, but the
  cart answers `E6 D6 60` only (the keyboard carts send `02 02 E6 D6 60`),
  and the device must not send a layout byte after it (the cart would read
  `40`-`44` as a pen header).  The ID the real tablet sends is unknown; the
  model uses `54`.
* X is horizontal and Y vertical, both about screen pixels: the cart's arrow
  cursor sits at about (X, Y + 4).  Found by sweeping the pen in the sim; X
  beyond ~335 pins the cursor at the right edge.
* The cart answers the handshake and deselects the port at once; a device
  that queues its first report at that moment raises RTS while the cart is
  busy and the cart never sees the edge.  The model drops and re-raises RTS
  after 20 ms queued and unselected (MAME's controller base would wait
  forever too; its 2 s RTS timer is commented out).
* Pen states, from the sim: `40` moves the cursor, `41` presses (a menu
  item is taken on the press), `42` sends the cursor to the corner.  The
  model sends `40`/`41` with the position on every change and never `42`
  (a mouse is always "in range").  Menus and the drawing screen ignore the
  pen while they animate in or the mascot narrates.
* The canvas lives in the cart's RAM: MAME's `vsmile_nvram` carts (the five
  Art Studio carts, and no others) have 2 MB of RAM in the upper half of
  the cart space (chip-select mode 1: 200000-3FFFFF, modes 2/3:
  200000-2FFFFF).  Without it the cart runs its drawing code but nothing
  appears.  The core keeps it in SDRAM (words C00000-CFFFFF), zeroed when
  such a cart loads (MAME's fill without a save file); CPU writes to it are
  posted through the SoC's ext cache (which drops cached copies) and kept in
  order with reads in the SDRAM glue.  Not saved to SD yet.

MiSTer: Port 1 "Art Studio" (Auto for product numbers 80-0670xx, which also
turns the cart RAM on); a USB mouse moves the pen a screen pixel per count
and its left button presses it; the left stick moves it too, pad B presses
it; OK/Quit/Help as usual.

## SmartBook (not implemented)

The protocol is the same pen packet plus the page bytes.  The problem is the
book: its printed pages are what the child touches, and they are not in the
ROM, so an emulated pen needs scans of each book shown on screen and
calibrated to X/Y.  Two carts are known (Toy Story 2, Dora's Got a Puppy).
