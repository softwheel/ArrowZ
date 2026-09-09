"""Install the pinned Linux x86_64 compiler for CI, verifying the archive hash."""
import hashlib
import pathlib
import sys
import tarfile
import urllib.request

version = pathlib.Path('.zigversion').read_text().strip()
if version != '0.16.0':
    raise SystemExit('Update the pinned download digest with the toolchain version')
destination = pathlib.Path(sys.argv[1]).resolve()
destination.mkdir(parents=True, exist_ok=True)
archive = destination / 'zig.tar.xz'
url = f'https://ziglang.org/download/{version}/zig-x86_64-linux-{version}.tar.xz'
with urllib.request.urlopen(url, timeout=120) as response, archive.open('wb') as out:
    while chunk := response.read(1024 * 1024):
        out.write(chunk)
expected = '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00'
if hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest() != expected:
    raise SystemExit('Zig archive SHA-256 mismatch')
with tarfile.open(archive) as tar:
    tar.extractall(destination, filter='data')
print(destination / f'zig-x86_64-linux-{version}')
