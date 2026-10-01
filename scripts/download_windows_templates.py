"""Fetch only Windows x64 entries from the official Godot templates ZIP.

HTTP ranges avoid downloading the 1.28 GB of templates for other platforms.
zipfile verifies the CRC of each fully extracted entry. Use HTTPS official URL
and preserve a receipt with entry hashes; this is not a whole-archive hash check.
"""
import argparse
import hashlib
import io
import json
import pathlib
import time
import urllib.request
import zipfile


class RemoteZip(io.RawIOBase):
    def __init__(self, url, size):
        self.url, self.size, self.position = url, size, 0
        self.cache = []

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        self.position = offset if whence == 0 else self.position + offset if whence == 1 else self.size + offset
        return self.position

    def read(self, count=-1):
        if count < 0:
            count = self.size - self.position
        count = min(count, self.size - self.position)
        if count <= 0:
            return b""
        begin, end = self.position, self.position + count
        for start, data in self.cache:
            if start <= begin and end <= start + len(data):
                self.position = end
                return data[begin - start:end - start]
        stop = min(self.size, max(end, begin + 65536))
        request = urllib.request.Request(self.url, headers={"Range": f"bytes={begin}-{stop - 1}", "User-Agent": "DesktopFarmBuild/0.6"})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    if response.status != 206:
                        raise RuntimeError(f"Server did not honor HTTP range (status {response.status})")
                    if not response.headers.get("Content-Range", "").startswith(f"bytes {begin}-{stop - 1}/"):
                        raise RuntimeError("Incorrect HTTP content range")
                    data = response.read()
                    self.url = response.geturl()
                if len(data) != stop - begin:
                    raise RuntimeError("Truncated download")
                break
            except Exception:
                if attempt == 3:
                    raise
                time.sleep(2)
        self.cache.append((begin, data))
        if sum(len(entry[1]) for entry in self.cache) > 150_000_000:
            self.cache = self.cache[-3:]
        self.position = end
        return data[:count]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--assets", default=".tools/release-assets.json")
    parser.add_argument("--output", default=".tools/export-templates")
    args = parser.parse_args()
    asset = next(a for a in json.loads(pathlib.Path(args.assets).read_text(encoding="utf-8-sig")) if a["name"].endswith("_export_templates.tpz") and "mono" not in a["name"])
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    receipt = {"official_url": asset["browser_download_url"], "archive_size": asset["size"], "archive_digest": asset["digest"], "verification": "HTTPS ranges plus ZIP CRC for each entry; archive SHA256 not verified", "files": []}
    with zipfile.ZipFile(RemoteZip(asset["browser_download_url"], asset["size"])) as archive:
        entries = [entry for entry in archive.infolist() if entry.filename.rsplit("/", 1)[-1] in ("windows_release_x86_64.exe", "windows_debug_x86_64.exe")]
        if len(entries) != 2:
            raise RuntimeError(f"Windows x64 entries missing: {[i.filename for i in archive.infolist()]}")
        entries.sort(key=lambda entry: "release" not in entry.filename)
        for entry in entries:
            print(f"Download {entry.filename}: {entry.compress_size:,} compressed bytes", flush=True)
            data = archive.read(entry)
            path = output / pathlib.PurePosixPath(entry.filename).name
            path.write_bytes(data)
            receipt["files"].append({"name": path.name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "zip_crc32": f"{entry.CRC:08x}"})
            print(f"Verified ZIP CRC and saved {path}", flush=True)
    (output / "download-receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
