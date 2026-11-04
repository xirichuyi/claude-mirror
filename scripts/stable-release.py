"""Build and publish one complete stable release. Commands run from the repository root."""
import base64
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.etree import ElementTree as ET

INSTALLER = "Claude-Mirror-Setup-x64.exe"
PORTABLE = "claude-mirror-windows-x64.zip"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
REPO = "xirichuyi/claude-mirror"


def version(tag):
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}", tag):
        raise ValueError(f"Expected a stable vMAJOR.MINOR.PATCH tag, got {tag!r}")
    return tuple(map(int, tag[1:].split(".")))


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def manifest(tag, folder):
    version(tag)
    exe = folder / INSTALLER
    return {"tag": tag, "asset": INSTALLER, "length": exe.stat().st_size, "sha256": digest(exe)}


def verify_assets(tag, folder):
    dmg = f"claude-mirror-{tag[1:]}-macOS-arm64.dmg"
    names = ["appcast.xml", "windows-update.json", "windows-update.sig", "setup-remote.sh", "install-claude-remote.sh"]
    for name in (INSTALLER, PORTABLE, dmg):
        expected = (folder / (name + ".sha256")).read_text().split()[0].lower()
        if expected != digest(folder / name):
            raise ValueError(f"Checksum mismatch: {name}")
        names.extend([name, name + ".sha256"])
    if json.loads((folder / "windows-update.json").read_bytes()) != manifest(tag, folder):
        raise ValueError("Windows manifest does not describe this release")
    if len(base64.b64decode((folder / "windows-update.sig").read_text().strip(), validate=True)) != 64:
        raise ValueError("Invalid Windows manifest signature")
    item = ET.parse(folder / "appcast.xml").find(".//item")
    enclosure = item.find("enclosure")
    if (item.findtext(SPARKLE + "shortVersionString") != tag[1:]
            or enclosure.get("url") != f"https://github.com/{REPO}/releases/download/{tag}/{dmg}"
            or int(enclosure.get("length")) != (folder / dmg).stat().st_size
            or not enclosure.get(SPARKLE + "edSignature")):
        raise ValueError("Sparkle feed and macOS installer do not match")
    return {name: "sha256:" + digest(folder / name) for name in names}


def gh(*args):
    return subprocess.check_output(["gh", *map(str, args)], text=True)


def release(tag=None):
    # Only a 404 means absent; propagate network and permission failures.
    path = "latest" if tag is None else f"tags/{tag}"
    result = subprocess.run(["gh", "api", f"repos/{REPO}/releases/{path}"], capture_output=True, text=True)
    if result.returncode and "HTTP 404" in result.stderr:
        if tag:
            # The tag endpoint can hide drafts; authenticated release listings include them.
            ids = gh("api", "--paginate", f"repos/{REPO}/releases", "--jq",
                     f'.[] | select(.draft and .tag_name == "{tag}") | .id').split()
            if ids:
                return json.loads(gh("api", f"repos/{REPO}/releases/{ids[0]}"))
        return None
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def verify_remote(data, expected):
    assets = {a["name"]: a.get("digest") for a in data["assets"] if a.get("state") == "uploaded"}
    if any(assets.get(name) != value for name, value in expected.items()):
        raise RuntimeError("Release assets incomplete or different from validated build")


def publish(tag, folder):
    expected = verify_assets(tag, folder)
    head = release()
    if head and version(head["tag_name"]) > version(tag):
        raise RuntimeError("Refusing to promote an older release")
    current = release(tag)
    if current and not current["draft"]:
        # On retry after publication, use the bytes that users already received.
        # Signing and packaging a second time can produce a different artifact.
        with tempfile.TemporaryDirectory() as temp:
            public = Path(temp)
            gh("release", "download", tag, "--repo", REPO, "--dir", public)
            verify_remote(current, verify_assets(tag, public))
            feed = Path("macos/dist/appcast.xml")
            feed.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(public / "appcast.xml", feed)
        return
    if not current:
        gh("release", "create", tag, "--repo", REPO, "--verify-tag", "--draft", "--title", f"Claude Mirror {tag}",
           "--notes-file", f"docs/releases/{tag}.md")
    gh("release", "upload", tag, *(folder / name for name in expected), "--repo", REPO, "--clobber")
    verify_remote(release(tag), expected)
    # Reject reused Sparkle build numbers before making the release visible.
    if head and any(a["name"] == "appcast.xml" for a in head["assets"]):
        with tempfile.TemporaryDirectory() as temp:
            gh("release", "download", head["tag_name"], "--repo", REPO, "--pattern", "appcast.xml", "--dir", temp)
            def build(path):
                return int(ET.parse(path).findtext(".//item/" + SPARKLE + "version"))
            if build(folder / "appcast.xml") <= build(Path(temp) / "appcast.xml"):
                raise RuntimeError("Increment CFBundleVersion before publishing")
    gh("release", "edit", tag, "--repo", REPO, "--draft=false", "--latest")
    verify_remote(release(tag), expected)
    feed = Path("macos/dist/appcast.xml")
    feed.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(folder / "appcast.xml", feed)


if __name__ == "__main__":
    action, tag, directory = sys.argv[1:]
    version(tag)
    folder = Path(directory)
    if action == "manifest":
        (folder / "windows-update.json").write_bytes((json.dumps(manifest(tag, folder)) + "\n").encode())
    elif action == "publish":
        publish(tag, folder)
    elif action == "verify":
        verify_assets(tag, folder)
    else:
        raise SystemExit("Expected manifest or publish")
