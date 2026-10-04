"""Writes src/tables.zig and the conformance tests in tests/data from the
Unicode Character Database.

    python scripts/generate.py UCD.zip

UCD.zip is https://www.unicode.org/Public/<version>/ucd/UCD.zip.
"""
import sys
import zipfile
from pathlib import Path

VERSION = '17.0.0'
ROOT = Path(__file__).resolve().parent.parent

# The order gives the values of the enums in tables.zig.
BREAK = ['other', 'control', 'cr', 'lf', 'extend', 'zwj', 'regional_indicator',
         'prepend', 'spacingmark', 'l', 'v', 't', 'lv', 'lvt']
CONJUNCT = ['none', 'consonant', 'extend', 'linker']
WORD = ['other', 'cr', 'lf', 'newline', 'extend', 'zwj', 'regional_indicator',
        'format', 'katakana', 'hebrew_letter', 'aletter', 'single_quote',
        'double_quote', 'midnumlet', 'midletter', 'midnum', 'numeric',
        'extendnumlet', 'wsegspace']
LAST = 0x10ffff


def records(archive, name, accept=lambda fields: fields[1]):
    """The (first, last, value) of every line of a UCD file that `accept`
    gives a value for."""
    rows = []
    for line in archive.read(name).decode().splitlines():
        fields = [s.strip() for s in line.split('#')[0].split(';')]
        if len(fields) < 2:
            continue
        value = accept(fields)
        if value is None:
            continue
        bounds = fields[0].split('..')
        rows.append((int(bounds[0], 16), int(bounds[-1], 16), value.lower()))
    return rows


def load(archive):
    return {
        'break': records(archive, 'auxiliary/GraphemeBreakProperty.txt'),
        'word': records(archive, 'auxiliary/WordBreakProperty.txt'),
        'conjunct': records(archive, 'DerivedCoreProperties.txt',
                            lambda f: f[2] if f[1] == 'InCB' else None),
        'pictographic': records(archive, 'emoji/emoji-data.txt',
                                lambda f: 'yes' if f[1] == 'Extended_Pictographic' else None),
    }


def spread(rows, values, shift):
    """One number per code point: the index of its value, moved up by
    `shift` bits."""
    points = [0] * (LAST + 1)
    for first, last, value in rows:
        points[first:last + 1] = [values.index(value) << shift] * (last - first + 1)
    return points


def runs(*layers):
    """The code points where the combined layers change, each with the
    combination that starts there, as `first << 8 | combination`."""
    entries = []
    before = None
    for point in range(LAST + 1):
        combined = 0
        for layer in layers:
            combined |= layer[point]
        if combined != before:
            entries.append(point << 8 | combined)
            before = combined
    return entries


def table(name, entries):
    lines = [f'pub const {name} = [_]u32{{']
    for start in range(0, len(entries), 8):
        lines.append('    ' + ' '.join(f'0x{entry:08x},' for entry in entries[start:start + 8]))
    lines.append('};')
    return lines


def enum(name, tag, values):
    return [f'pub const {name} = enum({tag}) {{'] + [f'    {value},' for value in values] + ['};']


def emit(tables):
    pictographic = tables['pictographic']
    out = [
        f'// Generated from the Unicode Character Database {VERSION} by',
        '// scripts/generate.py. Unicode data license:',
        '// https://www.unicode.org/license.txt',
        '//',
        '// A table holds the code points where its property changes: the code',
        '// point in the upper 24 bits and what starts there in the lower 8.',
        '',
        f'pub const version = "{VERSION}";',
        '',
    ]
    out += enum('Break', 'u4', BREAK) + ['']
    out += enum('Conjunct', 'u2', CONJUNCT) + ['']
    out += enum('WordBreak', 'u5', WORD)
    out += [
        '',
        '// Break in bits 0 to 3, Conjunct in bits 4 and 5, and bit 6 for',
        '// Extended_Pictographic.',
    ]
    out += table('clusters', runs(
        spread(tables['break'], BREAK, 0),
        spread(tables['conjunct'], CONJUNCT, 4),
        spread(pictographic, ['no', 'yes'], 6),
    ))
    out += ['', '// WordBreak in bits 0 to 4, and bit 5 for Extended_Pictographic.']
    out += table('words', runs(
        spread(tables['word'], WORD, 0),
        spread(pictographic, ['no', 'yes'], 5),
    ))
    return '\n'.join(out) + '\n'


if __name__ == '__main__':
    archive = zipfile.ZipFile(sys.argv[1])
    (ROOT / 'src/tables.zig').write_text(emit(load(archive)))
    for name in ['GraphemeBreakTest', 'WordBreakTest']:
        (ROOT / f'tests/data/{name}.txt').write_bytes(archive.read(f'auxiliary/{name}.txt'))
