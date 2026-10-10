#!/usr/bin/env python3
"""Fingerprint the exact production inputs and executable for release verification."""
import hashlib, json, pathlib, plistlib, subprocess, sys
from datetime import datetime, timezone
ROOT = pathlib.Path(__file__).resolve().parents[1]
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def source_digest():
    paths = [ROOT/'Info.plist', ROOT/'Resources/AppIcon.icns', ROOT/'build.sh']
    paths += [p for p in (ROOT/'Sources').rglob('*.swift') if 'Tests' not in p.parts]
    h = hashlib.sha256()
    for p in sorted(paths):
        h.update(str(p.relative_to(ROOT)).encode()); h.update(b'\0'); h.update(p.read_bytes())
    return h.hexdigest()
def source_commit():
    """HEAD when the production inputs are committed and clean, so a release can name its source; else None."""
    git = ['git','-C',str(ROOT)]
    try:
        dirty = subprocess.check_output(git+['status','--porcelain','--untracked-files=all','--',
            'Info.plist','Resources/AppIcon.icns','build.sh','Sources'],text=True).strip()
        return None if dirty else subprocess.check_output(git+['rev-parse','HEAD'],text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
if __name__ == '__main__':
    app, out = map(pathlib.Path, sys.argv[1:])
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    meta = {'version':info['CFBundleShortVersionString'], 'build':info['CFBundleVersion'],
      'bundle_id':info['CFBundleIdentifier'], 'minimum_macos':info['LSMinimumSystemVersion'],
      'architecture':'Apple Silicon (arm64)', 'source_sha256':source_digest(),
      'executable_sha256':digest(app/'Contents/MacOS/KeyScope'),
      'built_at':datetime.now(timezone.utc).isoformat(),
      'sdk':subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-version'],text=True).strip()}
    commit = source_commit()
    if commit: meta['source_commit'] = commit
    out.write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n')
