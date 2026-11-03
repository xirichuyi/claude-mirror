"""Feed publishing must preserve signatures and never downgrade clients."""
import base64
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publish", Path(__file__).with_name("publish-appcast.py"))
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


def feed(build):
    return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>{build}</sparkle:version></item></channel></rss><!-- signature stays unchanged -->'.encode()


class FeedPublishingTests(unittest.TestCase):
    def run_publish(self, old_build, new_build):
        calls = []
        def api(endpoint, payload=None):
            calls.append((endpoint, payload))
            if endpoint.startswith("git/matching"):
                return json.dumps([{"ref": "refs/heads/updates"}])
            if endpoint.startswith("contents/?"):
                return json.dumps([{"name": "appcast.xml"}])
            if endpoint.startswith("contents/appcast.xml?"):
                return json.dumps({"sha": "previous-sha", "content": base64.b64encode(feed(old_build)).decode()})
            return '{}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'appcast.xml'
            path.write_bytes(feed(new_build))
            with patch.object(publish, 'api', api), patch.object(publish, 'FEED', path):
                publish.publish()
        return calls

    def test_signed_bytes_and_previous_sha_are_preserved(self):
        calls = self.run_publish(5, 6)
        endpoint, payload = calls[-1]
        self.assertEqual(endpoint, 'contents/appcast.xml')
        self.assertEqual(payload['sha'], 'previous-sha')
        self.assertEqual(base64.b64decode(payload['content']), feed(6))

    def test_older_release_cannot_overwrite_new_feed(self):
        with self.assertRaisesRegex(RuntimeError, 'older release'):
            self.run_publish(7, 6)


if __name__ == '__main__':
    unittest.main()
