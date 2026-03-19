#!/usr/bin/env python3

# SPDX-License-Identifier: CC0-1.0
#
# SPDX-FileContributor: Antonio Niño Díaz, 2024

import os

from architectds import *

profile = os.environ.get("NDS_BUILD_PROFILE", "release").strip().lower()
if profile not in ("release", "debug"):
    raise ValueError(
        "Invalid NDS_BUILD_PROFILE. Expected 'release' or 'debug'. "
        f"Got: {profile}"
    )

is_debug = profile == "debug"
rom_name = os.environ.get("NDS_ROM_NAME")
if not rom_name:
    base_name = os.path.basename(os.getcwd())
    rom_name = f"{base_name}-debug.nds" if is_debug else f"{base_name}.nds"

arm9_cflags = "-Wall -O0 -g3 -DDEBUG -std=gnu11" if is_debug else "-Wall -O2 -DNDEBUG -std=gnu11"

nitrofs = NitroFS()
nitrofs.add_grit(['assets/robot'])
nitrofs.add_nitro_engine_md5(['assets/robot'])
nitrofs.add_nflib_bg_tiled(['assets/bg'], 'bg')
nitrofs.add_nflib_sprite_256(['assets/sprite'], 'sprite')
nitrofs.add_nflib_font(['assets/fnt'], 'fnt')
nitrofs.generate_image()

arm9 = Arm9Binary(
    sourcedirs=['source'],
    libs=['NE', 'nflib', 'nds9'],
    cflags=arm9_cflags,
    libdirs=[
        '${BLOCKSDS}/libs/libnds',
        '${BLOCKSDSEXT}/nitro-engine',
        '${BLOCKSDSEXT}/nflib'
    ]
)
arm9.generate_elf()

nds = NdsRom(
    binaries=[arm9, nitrofs],
    game_title='NE: NFlib: Template [DBG]' if is_debug else 'NE: NFlib: Template',
    nds_path=rom_name,
)
nds.generate_nds()

nds.run_command_line_arguments()
