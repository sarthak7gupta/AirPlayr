#!/usr/bin/env python3.14
"""Hash repository fixtures offline; codec probing is required only for deliberate regeneration."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
folder = root / 'AirPlayrTests/Fixtures'
extensions = {'.mp4', '.mkv', '.mov', '.m4v', '.wav', '.aac', '.m4a', '.mp3', '.aiff', '.aif', '.caf', '.flac'}
manifest = folder / 'manifest.json'
writing = '--write' in sys.argv
probe = shutil.which('ffprobe') if writing else None
if writing and not probe:
    sys.exit('Regenerating metadata requires a developer ffprobe. Normal --check needs only Python.')
entries = []
for path in sorted(folder.rglob('*')):
    if not path.is_file() or path.suffix.lower() not in extensions:
        continue
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    entry = {'file': str(path.relative_to(folder)), 'bytes': path.stat().st_size, 'sha256': digest}
    if writing:
        result = subprocess.run([probe, '-v', 'error', '-show_entries',
            'format=format_name,duration:format_tags=major_brand:stream=codec_type,codec_name,codec_tag_string,width,height,channels,pix_fmt',
            '-of', 'json', '-i', str(path)], capture_output=True, check=True, text=True)
        entry['media'] = json.loads(result.stdout)
    entries.append(entry)
if writing:
    manifest.write_text(json.dumps({'fixtures': entries}, indent=2) + '\n')
    print(f'Wrote manifest for {len(entries)} repository fixtures')
else:
    declared = json.loads(manifest.read_text())['fixtures'] if manifest.exists() else []
    identity = lambda entry: {key: entry[key] for key in ('file', 'bytes', 'sha256')}
    if [identity(entry) for entry in declared] != entries:
        sys.exit('Fixture content differs. Review the changes, then regenerate with --write.')
    print(f'Verified {len(entries)} fixture hashes; codec/container metadata describes those exact bytes')
