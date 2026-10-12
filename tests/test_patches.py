from paths import ROOT
import os
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from patches import (compile_patches, external_patches, external_selection, compile_external,
                     game_profile, selected_patches, patch_requirements)

GOW3 = ROOT / 'patches/God_of_War_III_Remastered.xml'
GOW3_IDS = {'CUSA01623'}
SEGMENTS = [(0, 0x6000000)]


EXTERNAL = """<?xml version="1.0"?>
<Patch>
  <TitleID><ID>CUSA01623</ID></TitleID>
  <Metadata Title="God of War III" Name="On" Author="x" PatchVer="1.0" AppVer="01.02" AppElf="eboot.bin" isEnabled="true">
    <PatchList><Line Type="bytes" Address="0x00401000" Value="9090"/></PatchList>
  </Metadata>
  <Metadata Title="God of War III" Name="Off" Author="x" PatchVer="1.0" AppVer="01.02" AppElf="eboot.bin">
    <PatchList><Line Type="bytes32" Address="0x00402000" Value="0x12345678"/></PatchList>
  </Metadata>
  <Metadata Title="God of War III" Name="Mask" Author="x" PatchVer="1.0" AppVer="01.02" AppElf="eboot.bin" isEnabled="true">
    <PatchList><Line Type="mask" Value="90 ?? 90" Offset="0"/></PatchList>
  </Metadata>
  <Metadata Title="God of War III" Name="Old" Author="x" PatchVer="1.0" AppVer="01.00" AppElf="eboot.bin" isEnabled="true">
    <PatchList><Line Type="bytes" Address="0x00403000" Value="90"/></PatchList>
  </Metadata>
</Patch>"""


class ExternalPatchTests(unittest.TestCase):
    def test_selection_and_unsupported_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'extra.xml').write_text(EXTERNAL)
            (folder / 'other.xml').write_text(EXTERNAL.replace('CUSA01623', 'CUSA99999'))
            (folder / 'broken.xml').write_text('<Patch>')
            found = external_patches(folder, '01.02', GOW3, GOW3_IDS)
            self.assertEqual([key for key, _, _ in found],
                             ['extra.xml/On', 'extra.xml/Off', 'extra.xml/Mask'])
            # The file's isEnabled; the mask patch is skipped as a whole.
            writes = compile_external(external_selection(found, None), SEGMENTS)
            self.assertEqual(writes, [(0x1000, bytes.fromhex('9090'))])
            config = folder / 'patches.json'
            config.write_text('{"enabled": ["extra.xml/Off"], "disabled": ["extra.xml/On"]}')
            writes = compile_external(external_selection(found, config), SEGMENTS)
            self.assertEqual(writes, [(0x2000, (0x12345678).to_bytes(4, 'little'))])

    def test_built_in_file_is_not_external(self):
        self.assertEqual(external_patches(GOW3.parent, '01.02', GOW3, GOW3_IDS), [])


class GameProfileTests(unittest.TestCase):
    def test_profiles_by_title_id(self):
        self.assertEqual(game_profile('CUSA01623')[1:3], (GOW3, '01.02'))
        self.assertIsNone(game_profile('CUSA99999'))
        self.assertIsNone(game_profile(None))

    def test_gow3_defaults_and_extras(self):
        self.assertEqual(selected_patches(GOW3, '01.02', ''),
                         ['Bug Fix - Texture Corruption Fix', 'Skip Any Video With X Button'])
        self.assertEqual(selected_patches(GOW3, '01.02', 'Resolution Patch - 720p; Skip Any Video With X Button'),
                         ['Skip Any Video With X Button', 'Resolution Patch - 720p'])
        self.assertEqual(selected_patches(GOW3, '01.00', ''), [])
        # The launcher's selection is exact: unchecked defaults stay off.
        self.assertEqual(selected_patches(GOW3, '01.02', 'Skip Any Video With X Button', only=True), ['Skip Any Video With X Button'])
        self.assertEqual(selected_patches(GOW3, '01.02', '', only=True), [])

    def test_gow3_resolution_patch_replaces_texture_fix(self):
        self.assertEqual(selected_patches(GOW3, '01.02', 'Resolution Patch - 4K'),
                         ['Skip Any Video With X Button', 'Resolution Patch - 4K'])
        with self.assertRaises(ValueError):
            selected_patches(GOW3, '01.02', 'Resolution Patch - 4K;Resolution Patch - 720p')

    def test_eboot_build_check(self):
        from patches import eboot_matches
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'eboot.bin').write_bytes(b'another build')
            self.assertFalse(eboot_matches(folder, game_profile('CUSA01623')))
            self.assertTrue(eboot_matches(folder, None))  # no profile: nothing to check

    def test_unported_build(self):
        import hashlib
        from unittest import mock
        import patches
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'eboot.bin').write_bytes(b'full update')
            self.assertIsNone(patches.unported_build(folder))  # unknown build
            sha = hashlib.sha256(b'full update').hexdigest()
            with mock.patch.dict(patches.UNPORTED_BUILDS, {sha: 'full 01.02 update'}):
                self.assertEqual(patches.unported_build(folder), 'full 01.02 update')
        self.assertIsNone(patches.unported_build(None))
        self.assertIn('6e72330e9092e5164049b865e5568f2d450904001a73fe0a2f4b39194c195b3c',
                      patches.UNPORTED_BUILDS)

    def test_game_patchable(self):
        from patches import game_patchable
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / 'eboot.bin').write_bytes(b'another build')
            self.assertFalse(game_patchable(folder))  # no param.sfo: unknown game
            self.assertFalse(game_patchable(None))

    def test_gow3_patches_compile(self):
        names = [m.get('Name') for m in ET.parse(GOW3).getroot().iter('Metadata')]
        self.assertTrue(compile_patches(GOW3, names, '01.02', SEGMENTS))

    def test_gow3_skip_intro_targets(self):
        # Ported from the other 01.02 build: every jump must land where this eboot has the code.
        writes = dict(compile_patches(GOW3, ['Skip Intro'], '01.02', SEGMENTS))
        rel = lambda data, at, end: end + int.from_bytes(data[at:at + 4], 'little', signed=True)
        self.assertEqual(writes[0x184950], bytes.fromhex('eb34'))  # jne over the logo start
        getter = writes[0x0c8440]  # mov [flag], 1; mov eax, 1; ret
        self.assertEqual(len(getter), 16)
        self.assertEqual(rel(getter, 2, 0x4c844a), 0x1e79258)
        call = writes[0x01b36a]  # the boot call now goes through the cave
        self.assertEqual(rel(call, 1, 0x41b36f), 0x612170)
        cave = writes[0x212170]  # mov [flag], 1; jmp to the original callee
        self.assertEqual(len(cave), 15)
        self.assertEqual(rel(cave, 2, 0x61217a), 0x1e79258)
        self.assertEqual(rel(cave, 11, 0x61217f), 0x4b4c90)

    @unittest.skipUnless(os.environ.get('GOW3_GAME'), 'GOW3_GAME (game folder) not set')
    def test_gow3_skip_intro_original_bytes(self):
        from prepare import parse_self
        elf, _, ph, _, _ = parse_self((Path(os.environ['GOW3_GAME']) / 'eboot.bin').read_bytes())
        text = next(p for p in ph if p['type'] == 1 and p['flags'] & 1)
        original = {0x184950: '7534', 0x0c8440: '488d05955b38008b00c3660f1f440000',
                    0x01b36a: 'e821990900', 0x212170: '90' * 15}
        for offset, value in original.items():
            at = text['offset'] + offset - text['vaddr']
            self.assertEqual(bytes(elf[at:at + len(value) // 2]).hex(), value, hex(offset))

    def test_requirements_from_patch_notes(self):
        # Notes ask for extra direct memory (shadPS4 "DMEM") and a VBlank rate.
        self.assertEqual(patch_requirements(GOW3, ['Resolution Patch - 4K', 'Skip Any Video With X Button'], '01.02'),
                         (5056 + 6144, None))
        self.assertEqual(patch_requirements(GOW3, ['Frame Rate Patch - 120 FPS'], '01.02'), (None, 120))
        self.assertEqual(patch_requirements(GOW3, [], '01.02'), (None, None))


if __name__ == '__main__':
    unittest.main()
