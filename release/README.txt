WATER EVERYWHERE — DEMO 0.1.0
=============================

Paddle a battered raft home to the mainland across a cel-shaded ocean.

STARTING
  Run WaterEVERYWHERE.exe and choose Play. You arrive on a small island.
  The raft is moored off the beach below you; the mountains ahead are the
  mainland. Get aboard, paddle across, and step ashore to finish.
  A crossing takes about five minutes.

CONTROLS
  WASD ............ walk / swim
  Mouse ........... look
  Shift ........... sprint           Alt ... slow
  F ............... climb aboard the raft (from the water or the beach)
  Space ........... paddle (hold to keep stroking)
  G ............... push the raft off the shallows, from the shore
  Q / E ........... dive / rise while swimming
  V ............... first / third person
  1 2 3 / C ....... sunny / overcast / stormy / cycle weather
  Esc ............. menu (pauses a solo game), settings, restart, quit

STEERING
  Each stroke turns the raft away from the side you stand on.
  Walk across the deck to the other side to turn back.
  With friends, paddle from both sides to go straight.

PLAYING WITH FRIENDS
  Main menu > Play with friends.
  One player chooses "Host a game"; the others type the host's IP address
  and choose Join. On the same network this just works. Over the internet
  the host must forward UDP port 27015 on their router. Up to 8 players.

SETTINGS
  Mouse sensitivity, volume, music, graphics quality (High / Medium / Low),
  fullscreen and a frame-rate readout, from the menu. If the game runs slowly,
  try Medium first, then Low.
  Saved to %APPDATA%\Godot\app_userdata\WaterEVERYWHERE\settings.cfg

KNOWN ISSUES
  - The player character has idle, walk and swim animations only; there is
    no paddling animation yet.
  - Online play needs a forwarded port; there is no lobby or invite system.
  - Paddling alone, the raft zig-zags: that is the steering, not a bug.
  - Windows may warn that the program is from an unknown publisher: the
    demo is not code-signed. Choose "More info" > "Run anyway".

Requires Windows 10 or 11 (64-bit) and a GPU with DirectX 12 or Vulkan support.
A Linux build (x86_64, Vulkan) is made from the same project.

Made with the Godot Engine. Licence notices are under Credits in the game.
