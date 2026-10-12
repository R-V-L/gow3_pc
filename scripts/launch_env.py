#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Shared launch environment for run.py (Windows) and run.sh (Linux).

One source for the graphics options, the selected patches and the direct memory (DMEM) /
VBlank those patches need. The two entry points used to duplicate this and drifted apart: the
Linux run.sh missed the GoW3 graphics defaults and the DMEM, so textures were corrupted and the
game faulted building its heaps.
"""
import os
import sys
from pathlib import Path

PORT = Path(__file__).resolve().parent.parent


def derive(game, config, state_path, env):
    """Plan one launch.

    game:       the game folder (eboot.bin)
    config:     gow3.ini path
    state_path: graphics_state.json path (restart confirmation)
    env:        the current environment (GOW3_PATCHES, GOW3_PATCHES_ONLY, explicit overrides)

    Returns:
      updates:     environment variables the graphics options become (GOW3_DEFERRED_READBACK,
                   GOW3_STALE_READBACK, GOW3_ASYNC_SHADERS, GOW3_UPSCALER, GOW3_READBACK_LINEAR)
      patch_names: the selected patch names, resolution and frame rate included
      dmem, vblank: MiB / Hz the selected patches need, or None
      reverted:    a restart never reached the game; the last good options were restored
    """
    sys.path.insert(0, str(PORT / 'scripts'))
    import graphics_options
    from patches import game_profile, game_title_id, patch_requirements, selected_patches

    graphics, reverted = graphics_options.prepare(config, state_path)
    updates = dict(graphics_options.environment(graphics))
    # The temporal upscalers and motion vectors are not calibrated for this game yet; linear
    # image readbacks fix its corrupted textures. Defaults only: an explicit value wins.
    for key, default in (('GOW3_UPSCALER', 'none'), ('GOW3_READBACK_LINEAR', '1')):
        if key not in env:
            updates[key] = default

    names, dmem, vblank = [], None, None
    profile = game_profile(game_title_id(game))
    if profile:
        names = selected_patches(profile[1], profile[2], env.get('GOW3_PATCHES', ''),
                                 env.get('GOW3_PATCHES_ONLY') == '1')
        # gow3.ini decides the resolution and frame rate patches (in-game menu, launcher).
        names = graphics_options.patch_names(names, graphics)
        dmem, vblank = patch_requirements(profile[1], names, profile[2])
    return {'updates': updates, 'patch_names': names, 'dmem': dmem, 'vblank': vblank,
            'reverted': reverted}


def _quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def main(argv):
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game', required=True, type=Path)
    p.add_argument('--config', required=True, type=Path)
    p.add_argument('--state', required=True, type=Path)
    p.add_argument('--shell', action='store_true',
                   help='print export KEY=VALUE lines (for run.sh) instead of JSON')
    a = p.parse_args(argv)
    plan = derive(a.game, a.config, a.state, dict(os.environ))
    if not a.shell:
        import json
        print(json.dumps(plan))
        return 0
    exports = dict(plan['updates'])
    if plan['patch_names']:
        exports['GOW3_PATCHES'] = ';'.join(plan['patch_names'])
        exports['GOW3_PATCHES_ONLY'] = '1'
    if plan['dmem']:
        exports['GOW3_DMEM_MB'] = str(plan['dmem'])
    if plan['vblank']:
        exports['GOW3_VBLANK_HZ'] = str(plan['vblank'])
    for key, value in exports.items():
        print(f'export {key}={_quote(str(value))}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
