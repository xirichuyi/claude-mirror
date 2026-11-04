import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("stable", Path(__file__).with_name("stable-release.py"))
stable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stable)


class ReleaseTests(unittest.TestCase):
    tag = "v1.2.3"

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(temp.name)
        self.folder = Path("staging")
        self.folder.mkdir()
        dmg = "claude-mirror-1.2.3-macOS-arm64.dmg"
        for name in (dmg, stable.INSTALLER, stable.PORTABLE):
            (self.folder / name).write_bytes(b"test")
            (self.folder / (name + ".sha256")).write_text(hashlib.sha256(b"test").hexdigest())
        (self.folder / "appcast.xml").write_text(
            f'<rss xmlns:sparkle="{stable.SPARKLE[1:-1]}"><channel><item><sparkle:version>2</sparkle:version>'
            f'<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><enclosure length="4" sparkle:edSignature="test" '
            f'url="https://github.com/{stable.REPO}/releases/download/{self.tag}/{dmg}"/></item></channel></rss>')
        for name in ("setup-remote.sh", "install-claude-remote.sh"):
            (self.folder / name).write_text("script")
        (self.folder / "windows-update.json").write_text(json.dumps(stable.manifest(self.tag, self.folder)))
        (self.folder / "windows-update.sig").write_text(stable.base64.b64encode(bytes(64)).decode())

    def test_missing_or_changed_package_fails_before_release_creation(self):
        (self.folder / stable.INSTALLER).write_bytes(b"altered")
        with patch.object(stable, "gh") as gh, self.assertRaises(ValueError):
            stable.publish(self.tag, self.folder)
        gh.assert_not_called()

    def test_draft_stays_private_if_github_omits_a_platform(self):
        draft = {"draft": True, "assets": []}
        with patch.object(stable, "release", return_value=draft) as release, patch.object(stable, "gh") as gh:
            release.side_effect = [None, None, draft]
            with self.assertRaisesRegex(RuntimeError, "incomplete"):
                stable.publish(self.tag, self.folder)
            self.assertIn("--draft", gh.call_args_list[0].args)
            self.assertFalse(any("edit" in call.args for call in gh.call_args_list))
            self.assertFalse(Path("macos/dist/appcast.xml").exists())

    def test_older_tag_cannot_become_latest(self):
        with patch.object(stable, "release", return_value={"tag_name": "v1.3.0"}), patch.object(stable, "gh") as gh:
            with self.assertRaisesRegex(RuntimeError, "older"):
                stable.publish(self.tag, self.folder)
            gh.assert_not_called()

    def test_publish_once_after_verified_upload(self):
        digests = stable.verify_assets(self.tag, self.folder)
        data = {"assets": [{"name": n, "digest": h, "state": "uploaded"} for n, h in digests.items()]}
        with patch.object(stable, "release", side_effect=[None, None, data, data]), patch.object(stable, "gh") as gh:
            stable.publish(self.tag, self.folder)
            self.assertEqual([call.args[1] for call in gh.call_args_list], ["create", "upload", "edit"])
            self.assertEqual(Path("macos/dist/appcast.xml").read_bytes(), (self.folder / "appcast.xml").read_bytes())


if __name__ == "__main__":
    unittest.main()
