import contextlib
import importlib.util
import io
import os
import pathlib
import tempfile
import sys
sys.dont_write_bytecode = True
import unittest
from unittest.mock import patch

script = pathlib.Path(__file__).resolve().parents[1] / 'Sources/JuicebarCore/Resources/ssh-usage.py'
with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {'HOME': root, 'CODEX_HOME': root, 'CLAUDE_CONFIG_DIR': root, 'XDG_DATA_HOME': root}), contextlib.redirect_stdout(io.StringIO()):
    spec = importlib.util.spec_from_file_location('collector', script)
    collector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collector)

class SSHPrivacyTests(unittest.TestCase):
    def test_claude_transmits_usage_without_content_or_paths(self):
        record = collector.sanitized('claude', {'type': 'assistant', 'timestamp': '2026-09-25T12:00:00Z', 'cwd': 'PRIVATE_PATH', 'requestId': 'r', 'message': {'id': 'm', 'model': 'claude', 'content': 'PRIVATE_CONTENT', 'usage': {'input_tokens': 10, 'output_tokens': 2, 'injected': 'PRIVATE_CONTENT'}}})
        self.assertEqual(record['message']['usage'], {'input_tokens': 10, 'output_tokens': 2})
        self.assertNotIn('PRIVATE_', str(record))

    def test_codex_metadata_drops_instructions_and_workspace(self):
        record = collector.sanitized('codex', {'type': 'session_meta', 'timestamp': '2026-09-25T12:00:00Z', 'payload': {'id': 'session', 'base_instructions': 'PRIVATE_CONTENT', 'cwd': 'PRIVATE_PATH', 'source': {'subagent': {'thread_spawn': {'parent_thread_id': 'parent'}}}}})
        self.assertEqual(record['payload'], {'id': 'session', 'forked_from_id': 'present'})
        self.assertNotIn('PRIVATE_', str(record))

    def test_conversation_records_are_ignored(self):
        self.assertIsNone(collector.sanitized('codex', {'type': 'response_item', 'payload': {'content': 'PRIVATE_CONTENT'}}))
        self.assertIsNone(collector.sanitized('claude', {'type': 'user', 'message': {'content': 'PRIVATE_CONTENT'}}))

if __name__ == '__main__':
    unittest.main()
