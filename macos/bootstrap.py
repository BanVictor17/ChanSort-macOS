"""Install the pinned, checksum-verified ARM64 .NET SDK inside this project only."""
import hashlib, json, pathlib, tarfile, urllib.request
root = pathlib.Path(__file__).resolve().parent.parent
metadata = json.loads((root / "macos/sdk.json").read_text())
archive = root / "sdk.tar.gz"
if not (root / ".sdk/dotnet").exists():
    print("Downloading local .NET SDK…", flush=True)
    urllib.request.urlretrieve(metadata["url"], archive)
    assert hashlib.sha512(archive.read_bytes()).hexdigest().lower() == metadata["hash"].lower(), "SDK checksum mismatch"
    (root / ".sdk").mkdir(exist_ok=True)
    with tarfile.open(archive) as package:
        package.extractall(root / ".sdk")
    archive.unlink()
