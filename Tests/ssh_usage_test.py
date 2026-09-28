import contextlib
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import sys
import subprocess
sys.dont_write_bytecode = True
import unittest
from unittest.mock import patch

script = pathlib.Path(__file__).resolve().parents[1] / 'Sources/JuicebarCore/Resources/ssh-usage.py'
with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {'HOME': root, 'CODEX_HOME': root, 'CLAUDE_CONFIG_DIR': root, 'XDG_DATA_HOME': root, 'PI_CODING_AGENT_DIR': root, 'PI_CODING_AGENT_SESSION_DIR': root, 'GEMINI_CLI_HOME': root, 'QWEN_RUNTIME_DIR': root, 'XDG_CONFIG_HOME': root, 'KILO_DB': ':memory:'}), contextlib.redirect_stdout(io.StringIO()):
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

    def test_pi_preserves_usage_and_drops_conversation_and_extension_data(self):
        usage = {'input': 10, 'output': 5, 'cacheRead': 30, 'cacheWrite': 20, 'totalTokens': 65,
                 'cost': {'total': 0.42, 'private': 'PRIVATE_CONTENT'}, 'private': 'PRIVATE_CONTENT'}
        for role in ('assistant', 'toolResult'):
            record = collector.sanitized('pi', {'type': 'message', 'id': 'entry', 'timestamp': '2026-09-25T12:00:00Z',
                'cwd': 'PRIVATE_PATH', 'message': {'role': role, 'timestamp': 1790337600000, 'provider': 'openai-codex',
                'model': 'test-model', 'usage': usage, 'content': 'PRIVATE_CONTENT', 'details': 'PRIVATE_CONTENT'}})
            self.assertEqual(record['id'], 'entry')
            self.assertEqual(record['message']['role'], role)
            self.assertEqual(record['message']['timestamp'], 1790337600000)
            self.assertEqual(record['message']['provider'], 'openai-codex')
            self.assertEqual(record['message']['usage']['cost'], {'total': 0.42})
            self.assertNotIn('PRIVATE_', str(record))
        for kind in ('compaction', 'branch_summary', 'usage'):
            record = collector.sanitized('pi', {'type': kind, 'id': 'entry', 'timestamp': '2026-09-25T12:00:00Z',
                'usage': usage, 'summary': 'PRIVATE_CONTENT', 'systemMessage': 'PRIVATE_CONTENT', 'details': 'PRIVATE_CONTENT'})
            self.assertEqual(record['usage']['totalTokens'], 65)
            self.assertNotIn('PRIVATE_', str(record))
        header = collector.sanitized('pi', {'type': 'session', 'id': 's', 'timestamp': '2026-09-25T12:00:00Z',
                                           'cwd': 'PRIVATE_PATH', 'parentSession': 'PRIVATE_PATH'})
        self.assertEqual(header, {'type': 'session', 'id': 's', 'timestamp': '2026-09-25T12:00:00Z'})

    def test_pi_rejects_nonusage_and_nonscalar_metadata(self):
        for row in [{'type': 'message', 'message': {'role': 'user', 'usage': {'input': 10}}},
                    {'type': 'custom', 'usage': {'input': 10}},
                    {'type': 'message', 'message': 'PRIVATE_CONTENT'}]:
            self.assertIsNone(collector.sanitized('pi', row))
        record = collector.sanitized('pi', {'type': 'usage', 'id': {'content': 'PRIVATE_CONTENT'},
                    'timestamp': {'content': 'PRIVATE_CONTENT'}, 'model': {'content': 'PRIVATE_CONTENT'},
                    'usage': {'input': True, 'output': float('inf'), 'cost': {'total': float('nan')}}})
        self.assertNotIn('PRIVATE_', str(record))
        self.assertEqual(record['usage'], {'cost': {}})

    def test_pi_remote_discovery_overrides_nested_files_and_incomplete_lines(self):
        for mode in ('default', 'agent-dir', 'session-dir'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as root:
                base = pathlib.Path(root)
                env = {**os.environ, 'HOME': root, 'CODEX_HOME': str(base / 'codex'),
                       'CLAUDE_CONFIG_DIR': str(base / 'claude'), 'XDG_DATA_HOME': str(base / 'xdg'),
                       'GEMINI_CLI_HOME': root, 'QWEN_RUNTIME_DIR': root, 'XDG_CONFIG_HOME': root, 'KILO_DB': ':memory:'}
                env.pop('PI_CODING_AGENT_DIR', None)
                env.pop('PI_CODING_AGENT_SESSION_DIR', None)
                directory = base / '.pi/agent/sessions'
                if mode != 'default':
                    env['PI_CODING_AGENT_DIR'] = str(base / 'custom')
                    directory = base / 'custom/sessions'
                if mode == 'session-dir':
                    env['PI_CODING_AGENT_SESSION_DIR'] = str(base / 'override')
                    directory = base / 'override'
                directory = directory / 'nested/project'
                directory.mkdir(parents=True)
                header = {'type': 'session', 'id': 's', 'timestamp': '2026-09-25T12:00:00Z', 'cwd': 'PRIVATE_PATH'}
                entry = {'type': 'message', 'id': 'm', 'timestamp': '2026-09-25T12:00:01Z',
                         'message': {'role': 'assistant', 'model': 'test', 'provider': 'openai-codex',
                                     'usage': {'input': 10, 'output': 5}, 'content': 'PRIVATE_CONTENT'}}
                session = directory / 's.jsonl'
                session.write_text(json.dumps(header) + '\n' + json.dumps(entry) + '\n' + json.dumps(entry))
                (directory / 'symlink.jsonl').symlink_to(session)
                result = subprocess.run([sys.executable, str(script)], env=env, text=True, capture_output=True, check=True)
                rows = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(sum('file' in row for row in rows), 1)
                records = [row['record'] for row in rows if 'record' in row]
                self.assertEqual([record['type'] for record in records], ['session', 'message'])
                self.assertEqual(rows[-1], {'done': True})
                self.assertNotIn('PRIVATE_', result.stdout)
                self.assertNotIn(root, result.stdout)

    def test_new_sources_transmit_only_allowlisted_usage_metadata(self):
        fixtures = {
            'gemini': {'type': 'gemini', 'id': 'g', 'timestamp': '2026-09-28T12:00:00Z', 'model': 'gemini',
                       'tokens': {'input': 100, 'cached': 60, 'output': 20, 'thoughts': 15, 'private': 'PRIVATE_CONTENT'}},
            'qwen': {'type': 'assistant', 'uuid': 'q', 'timestamp': '2026-09-28T12:00:00Z', 'model': 'qwen',
                     'usageMetadata': {'promptTokenCount': 100, 'candidatesTokenCount': 20, 'cachedContentTokenCount': 60, 'private': 'PRIVATE_CONTENT'}},
            'cline': {'role': 'assistant', 'id': 'c', 'ts': 1800000000000, 'modelInfo': {'id': 'custom', 'provider': 'custom'},
                      'metrics': {'inputTokens': 100, 'outputTokens': 20, 'cost': 0.3, 'private': 'PRIVATE_CONTENT'}},
            'roo': {'type': 'say', 'say': 'api_req_started', 'ts': 1800000000000,
                    'text': json.dumps({'tokensIn': 100, 'tokensOut': 20, 'cost': 0.4, 'request': 'PRIVATE_CONTENT'})},
        }
        for source, value in fixtures.items():
            with self.subTest(source=source):
                value.update(content='PRIVATE_CONTENT', cwd='PRIVATE_PATH', tools='PRIVATE_CONTENT', credentials='PRIVATE_CONTENT')
                result = collector.sanitized(source, value)
                self.assertIsNotNone(result)
                self.assertNotIn('PRIVATE_', str(result))
        checkpoint = collector.sanitized('gemini', {'$set': {'messages': [fixtures['gemini']], 'summary': 'PRIVATE_CONTENT'}})
        self.assertNotIn('PRIVATE_', str(checkpoint))
        self.assertEqual(len(checkpoint['messages']), 1)

    def test_document_versions_and_unrelated_records_are_rejected(self):
        for version in (None, 2, True):
            with self.assertRaises(ValueError):
                collector.document_records('cline', {'version': version, 'messages': []})
        self.assertEqual(collector.document_records('cline', {'version': 1, 'messages': []}), [])
        self.assertIsNone(collector.sanitized('gemini', {'type': 'user', 'tokens': {'input': 10}}))
        self.assertIsNone(collector.sanitized('qwen', {'type': 'user', 'usageMetadata': {'promptTokenCount': 10}}))
        self.assertIsNone(collector.sanitized('cline', {'role': 'user', 'metrics': {'inputTokens': 10}}))
        self.assertIsNone(collector.sanitized('roo', {'type': 'say', 'say': 'text', 'text': '{}'}))
        self.assertFalse(collector.accepts_log('roo', 'api_conversation_history.json'))
        self.assertFalse(collector.accepts_log('cline', 'ui_messages.json'))

    def test_gemini_and_qwen_environment_overrides(self):
        with tempfile.TemporaryDirectory() as root:
            base = pathlib.Path(root)
            gemini = base / 'gemini-home/.gemini/tmp/project/chats/session-test.jsonl'
            qwen = base / 'runtime/projects/project/chats/session.jsonl'
            for path in (gemini, qwen): path.parent.mkdir(parents=True)
            gemini.write_text(json.dumps({'type': 'gemini', 'id': 'g', 'tokens': {'input': 10, 'output': 5}}) + '\n')
            qwen.write_text(json.dumps({'type': 'assistant', 'uuid': 'q', 'usageMetadata': {'promptTokenCount': 10, 'candidatesTokenCount': 5}}) + '\n')
            env = {'HOME': root, 'GEMINI_CLI_HOME': str(base / 'gemini-home'), 'QWEN_HOME': str(base / 'ignored'), 'QWEN_RUNTIME_DIR': str(base / 'runtime')}
            result = subprocess.run([sys.executable, str(script)], env=env, text=True, capture_output=True, check=True)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual({row['source'] for row in rows if 'file' in row}, {'gemini', 'qwen'})
            self.assertEqual(sum('record' in row for row in rows), 2)

if __name__ == '__main__':
    unittest.main()
