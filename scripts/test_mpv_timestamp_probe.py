"""Pure fixture-manipulation checks; no libmpv loading or playback."""
import importlib.util
from pathlib import Path
import random
import unittest

_path = Path(__file__).resolve().parents[1] / "benchmarks/mpv_timestamp_probe.py"
_spec = importlib.util.spec_from_file_location("timestamp_probe", _path)
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)


class TimestampFixtureTests(unittest.TestCase):
    def test_pts_dts_encoding_preserves_prefix_and_marker_bits(self):
        rng = random.Random(4141)
        for prefix in (0x21, 0x31, 0x11):
            old = bytes((prefix, 0, 1, 0, 1))
            for n in [0, 1, (1 << 33) - 1, *(rng.randrange(1 << 33) for _ in range(1000))]:
                encoded = probe.encode_pts(old, n)
                self.assertEqual(probe.decode_pts(encoded), n)
                self.assertEqual(encoded[0] & 0xF0, prefix & 0xF0)
                self.assertEqual([encoded[i] & 1 for i in (0, 2, 4)], [1, 1, 1])

    def test_packet_roundtrip_preserves_non_timing_bytes(self):
        base, pts, dts, extension = 45_000_000, 45_126_000, 45_123_000, 257
        pcr = bytes(((base >> 25) & 255, (base >> 17) & 255,
                     (base >> 9) & 255, (base >> 1) & 255,
                     ((base & 1) << 7) | 0x7E | (extension >> 8), extension & 255))
        pes = bytes((0, 0, 1, 0xE0, 0, 0, 0x80, 0xC0, 10))
        pes += probe.encode_pts(bytes((0x31, 0, 1, 0, 1)), pts)
        pes += probe.encode_pts(bytes((0x11, 0, 1, 0, 1)), dts)
        packet = bytes((0x47, 0x41, 1, 0x37, 7, 0x10)) + pcr + pes
        packet += bytes((0x55,)) * (188 - len(packet))
        for shift in [-367.08, 500, 95439, -95439]:
            shifted = probe.shift_ts(packet, shift)
            self.assertEqual(probe.shift_ts(shifted, -shift), packet)
            self.assertEqual(shifted[:6], packet[:6])
            self.assertEqual(shifted[10] & 127, packet[10] & 127)
            self.assertEqual(shifted[11], packet[11])
            self.assertEqual(shifted[31:], packet[31:])
            self.assertEqual(probe.decode_pts(shifted[21:26]), (pts + round(shift * 90000)) % (1 << 33))
            self.assertEqual(probe.decode_pts(shifted[26:31]), (dts + round(shift * 90000)) % (1 << 33))

    def test_non_ts_input_is_rejected(self):
        with self.assertRaises(AssertionError):
            probe.shift_ts(b"short", 500)
        with self.assertRaises(AssertionError):
            probe.shift_ts(bytes(188), 500)


if __name__ == "__main__":
    unittest.main()
