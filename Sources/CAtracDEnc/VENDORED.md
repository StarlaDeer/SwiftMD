# Vendored atracdenc

`atracdenc/` holds the parts of [atracdenc](https://github.com/dcherednik/atracdenc) needed to
encode ATRAC3 (LP2/LP4), from commit `e16e9c6`, the version Web MiniDisc Pro builds.
atracdenc is licensed under the LGPL-2.1 (`atracdenc/LICENSE`).

Only the ATRAC3 encoder and what it depends on are included; the command-line tool, WAV/AEA/OMA
file I/O and libsndfile are not. `shim.cpp` feeds PCM from memory and collects frames in memory.

Local changes, each marked `SwiftMD` in the source:

- `atrac/atrac3_bitstream.h`: the bitstream writer takes any `ICompressedIO*` instead of `TOma*`.
- `atrac3denc.cpp`: `GetEncodeLambda` no longer requires the output to be a `TOma`.
