#!/usr/bin/env python3
"""Publish the signed feed unchanged, after its release assets are available."""
import base64
import json
import subprocess
from pathlib import Path
from xml.etree import ElementTree

REPO = "repos/xirichuyi/claude-mirror"
FEED = Path("macos/dist/appcast.xml")
VERSION = "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"


def api(endpoint, payload=None):
    command = ["gh", "api", f"{REPO}/{endpoint}"]
    if payload is not None:
        command += ["--method", "PUT" if endpoint.startswith("contents/") else "POST", "--input", "-"]
    return subprocess.run(command, input=json.dumps(payload) if payload else None,
                          text=True, capture_output=True, check=True).stdout


def publish():
    refs = json.loads(api("git/matching-refs/heads/updates"))
    if not any(ref["ref"] == "refs/heads/updates" for ref in refs):
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        api("git/refs", {"ref": "refs/heads/updates", "sha": commit})
    files = json.loads(api("contents/?ref=updates"))
    previous = next((file for file in files if file["name"] == "appcast.xml"), None)
    content = FEED.read_bytes()
    build = int(ElementTree.fromstring(content).find(f".//{VERSION}").text)
    payload = {"message": f"Publish macOS update build {build}", "branch": "updates",
               "content": base64.b64encode(content).decode()}
    if previous:
        old = json.loads(api("contents/appcast.xml?ref=updates"))
        old_content = base64.b64decode(old["content"])
        old_build = int(ElementTree.fromstring(old_content).find(f".//{VERSION}").text)
        if old_build > build:
            raise RuntimeError("Refusing to replace the feed with an older release")
        payload["sha"] = old["sha"]
    api("contents/appcast.xml", payload)
    print(f"Published signed macOS feed for build {build}")


if __name__ == "__main__":
    publish()
