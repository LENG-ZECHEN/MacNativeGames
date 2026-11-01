"""iPhone / iPad pacing: mtl_display_hz never exceeds the display link that signals the game's vsync (the link runs at the
screen's rate up to 120; the phone still draws at most 60). A source check: the iOS branch needs a device to run."""
import re
import unittest
from pathlib import Path

TOTK = Path(__file__).resolve().parents[1] / 'games/totk'


class IosDisplayPacingTests(unittest.TestCase):
    def test_the_link_rate_is_one_value(self):
        src = (TOTK / 'runtime/frontend_ios.m').read_text()
        link = re.search(r'preferredFrameRateRange\s*=\s*CAFrameRateRangeMake\(([^)]*)\)', src)
        self.assertIsNotNone(link)
        self.assertEqual([a.strip() for a in link.group(1).split(',')], ['TOTK_IOS_LINK_HZ'] * 3)
        self.assertRegex(src, r'int front_display_link_hz\(void\)\s*\{\s*return TOTK_IOS_LINK_HZ;\s*\}')
        self.assertRegex(src, r'#define TOTK_IOS_LINK_HZ link_hz_now\(\)')

    def test_phone_draws_at_most_60_on_a_120_hz_link(self):
        src = (TOTK / 'third_party/d2r_gfx/gfx/nvn/hle_nvn.c').read_text()
        body = re.search(r'^static int uncapped_cap\(int scr\) \{\n(.*?)^\}', src, re.S | re.M).group(1)
        self.assertIn('scr > 60 ? "60" : "display"', body)

    def test_display_hz_is_capped_by_the_link_on_ios(self):
        src = (TOTK / 'third_party/d2r_gfx/gfx/nvn/nvn_mtl.m').read_text()
        body = re.search(r'^int mtl_display_hz\(void\) \{\n(.*?)^\}', src, re.S | re.M).group(1)
        ios = body.split('#else', 1)[1].split('#endif', 1)[0]
        self.assertIn('maximumFramesPerSecond', ios)
        self.assertIn('front_display_link_hz()', ios)


if __name__ == '__main__':
    unittest.main()
