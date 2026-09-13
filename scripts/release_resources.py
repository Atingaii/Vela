"""Shared exact resource identities and dependency-free release validation."""
import pathlib
import struct
import wave

NOTIFICATION_SOUNDS = (
    'vela-approval.wav', 'vela-completed.wav', 'vela-error.wav',
)
UI_RESOURCES = ('index.html', 'app.js', 'i18n.js', 'app.css', 'app-icon.svg')
DEVELOPMENT_UI_RESOURCES = ('demo.js',)


def validate_regular_resource(path):
    path = pathlib.Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'Missing or linked release resource: {path.name}')


def validate_ui_resources(directory, *, allow_development=False):
    directory = pathlib.Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('UI resources must be an ordinary directory.')
    allowed = set(UI_RESOURCES)
    if allow_development:
        allowed.update(DEVELOPMENT_UI_RESOURCES)
    for path in directory.rglob('*'):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink():
            raise ValueError(f'Linked UI resource: {relative}')
        if path.is_dir() and any(name.startswith(relative + '/') for name in allowed):
            continue
        if relative not in allowed or not path.is_file():
            raise ValueError(f'Unexpected UI resource: {relative}')
    for name in UI_RESOURCES:
        validate_regular_resource(directory / name)


def validate_notification_sound(path):
    path = pathlib.Path(path)
    assert not path.is_symlink() and path.is_file(), f'Missing or linked sound: {path.name}'
    assert path.stat().st_size <= 128 * 1024, f'Oversized sound: {path.name}'
    with wave.open(str(path), 'rb') as sound:
        assert sound.getcomptype() == 'NONE', f'Sound must use linear PCM: {path.name}'
        assert sound.getnchannels() == 1 and sound.getsampwidth() == 2, f'Sound must be 16-bit mono: {path.name}'
        assert sound.getframerate() in (22050, 44100, 48000), f'Unsupported sample rate: {path.name}'
        count = sound.getnframes()
        duration = count / sound.getframerate()
        assert 0.05 <= duration <= 1.5, f'Alert must be short (0.05–1.5 s): {path.name}'
        frames = sound.readframes(count)
        assert len(frames) == count * 2, f'Truncated PCM data: {path.name}'
        samples = struct.unpack('<' + 'h' * count, frames)
        peak = max(abs(value) for value in samples)
        assert 0 < peak < 32767, f'Sound is silent or clipped: {path.name}'
    return duration
