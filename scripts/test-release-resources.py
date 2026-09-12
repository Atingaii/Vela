"""Check sound payload bounds using disposable PCM files; never plays audio."""
import pathlib
import struct
import tempfile
import unittest
import wave

from release_resources import validate_notification_sound


class SoundResourceTests(unittest.TestCase):
    def test_valid_sound_and_invalid_payloads(self):
        with tempfile.TemporaryDirectory(prefix='vela-sound-test-') as temporary:
            root = pathlib.Path(temporary)

            def make(name, seconds=0.2, sample=1000, channels=1):
                path = root / name
                with wave.open(str(path), 'wb') as output:
                    output.setparams((channels, 2, 22050, 0, 'NONE', 'not compressed'))
                    output.writeframes(struct.pack('<h', sample) * int(22050 * seconds) * channels)
                return path

            valid = make('valid.wav')
            self.assertAlmostEqual(validate_notification_sound(valid), 0.2)
            for bad in [make('long.wav', seconds=2), make('silent.wav', sample=0),
                        make('clipped.wav', sample=32767), make('stereo.wav', channels=2)]:
                with self.assertRaises(AssertionError):
                    validate_notification_sound(bad)
            linked = root / 'linked.wav'
            linked.symlink_to(valid)
            with self.assertRaises(AssertionError):
                validate_notification_sound(linked)
            malformed = root / 'truncated.wav'
            malformed.write_bytes(valid.read_bytes()[:-20])
            with self.assertRaises(AssertionError):
                validate_notification_sound(malformed)


if __name__ == '__main__':
    unittest.main()
