# Sent to Python over SSH stdin. Read-only: no files, packages or credentials are written.
import datetime, hashlib, json, os, pathlib, sqlite3, time, re, math

now = time.time()
since = now - 90 * 86400
skipped = 0

def emit(value):
    print(json.dumps(value, separators=(',', ':')), flush=True)

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()

def numbers(value, keys):
    if not isinstance(value, dict):
        return {}
    return {key: value[key] for key in keys if isinstance(value.get(key), (int, float)) and not isinstance(value.get(key), bool) and math.isfinite(value[key])}

usage_keys = ['input_tokens', 'output_tokens', 'cached_input_tokens', 'cache_write_input_tokens', 'total_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens']

def scalar(value):
    return value if isinstance(value, str) or isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else None

def sanitized(source, row):
    kind = row.get('type')
    timestamp = row.get('timestamp')
    if source == 'gemini':
        messages = row.get('messages')
        if isinstance(row.get('$set'), dict):
            messages = row['$set'].get('messages')
        if isinstance(messages, list):
            return {'messages': [clean for message in messages if isinstance(message, dict)
                                 for clean in [sanitized(source, message)] if clean]}
        if kind != 'gemini' or not isinstance(row.get('tokens'), dict):
            return None
        return {'type': kind, 'id': scalar(row.get('id')), 'timestamp': scalar(timestamp), 'model': scalar(row.get('model')),
                'tokens': numbers(row['tokens'], ['input', 'output', 'cached', 'thoughts', 'tool', 'total'])}
    if source == 'qwen':
        if kind != 'assistant' or not isinstance(row.get('usageMetadata'), dict):
            return None
        return {'type': kind, 'uuid': scalar(row.get('uuid')), 'timestamp': scalar(timestamp), 'model': scalar(row.get('model')),
                'usageMetadata': numbers(row['usageMetadata'], ['promptTokenCount', 'candidatesTokenCount', 'cachedContentTokenCount'])}
    if source == 'cline':
        if row.get('role') != 'assistant' or not isinstance(row.get('metrics'), dict):
            return None
        model = row.get('modelInfo') if isinstance(row.get('modelInfo'), dict) else {}
        return {'role': 'assistant', 'id': scalar(row.get('id')), 'ts': scalar(row.get('ts')),
                'modelInfo': {key: scalar(model.get(key)) for key in ['id', 'provider']},
                'metrics': numbers(row['metrics'], ['inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'cost'])}
    if source == 'roo':
        if kind != 'say' or row.get('say') != 'api_req_started' or not isinstance(row.get('text'), str):
            return None
        usage = json.loads(row['text'])
        return {'type': 'say', 'say': 'api_req_started', 'ts': scalar(row.get('ts')),
                'text': json.dumps(numbers(usage, ['tokensIn', 'tokensOut', 'cacheReads', 'cacheWrites', 'cost']))}
    if source == 'pi':
        # Allow only scalar metadata. No cwd, summaries, content, tools or extension details.
        result = {'type': kind, 'id': scalar(row.get('id')), 'timestamp': scalar(timestamp)}
        if kind == 'session':
            return result
        fields = row.get('message') if kind == 'message' else row
        if not isinstance(fields, dict) or not isinstance(fields.get('usage'), dict):
            return None
        if kind == 'message':
            if fields.get('role') not in ('assistant', 'toolResult'):
                return None
        elif kind not in ('compaction', 'branch_summary', 'usage'):
            return None
        usage = numbers(fields['usage'], ['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens'])
        usage['cost'] = numbers(fields['usage'].get('cost'), ['total'])
        selected = {key: scalar(fields.get(key)) for key in ['model', 'provider']}
        selected['usage'] = usage
        if kind == 'message':
            selected.update(role=fields['role'], timestamp=scalar(fields.get('timestamp')))
            result['message'] = selected
        else:
            result.update(selected)
        return result
    if source == 'claude':
        message = row.get('message', {})
        if kind != 'assistant' or not isinstance(message, dict) or not isinstance(message.get('usage'), dict):
            return None
        usage = numbers(message['usage'], usage_keys)
        if isinstance(message['usage'].get('cache_creation'), dict):
            usage['cache_creation'] = numbers(message['usage']['cache_creation'], ['ephemeral_1h_input_tokens', 'ephemeral_5m_input_tokens'])
        return {'type': kind, 'timestamp': timestamp, 'requestId': row.get('requestId'), 'message': {'id': message.get('id'), 'model': message.get('model'), 'usage': usage}}
    payload = row.get('payload', {})
    if not isinstance(payload, dict):
        return None
    if kind == 'session_meta':
        selected = {'id': payload.get('id') or payload.get('session_id')}
        if payload.get('forked_from_id') or isinstance(payload.get('source'), dict) and payload['source'].get('subagent'):
            selected['forked_from_id'] = 'present'
    elif kind == 'turn_context':
        selected = {'model': payload.get('model')}
    elif kind == 'token_usage_record':
        selected = {'response_id': payload.get('response_id'), 'usage': numbers(payload.get('usage'), usage_keys)}
    elif kind == 'event_msg' and payload.get('type') == 'token_count':
        info = payload.get('info') or {}
        if not isinstance(info, dict):
            return None
        selected = {'type': 'token_count', 'info': {key: numbers(info.get(key), usage_keys) for key in ['last_token_usage', 'total_token_usage']}}
    else:
        return None
    return {'type': kind, 'timestamp': timestamp, 'payload': selected}

home = pathlib.Path.home()
pi_dir = pathlib.Path(os.environ.get('PI_CODING_AGENT_DIR') or home / '.pi/agent').expanduser()
roots = [('codex', pathlib.Path(os.environ.get('CODEX_HOME', home / '.codex')) / 'sessions'),
         ('codex', pathlib.Path(os.environ.get('CODEX_HOME', home / '.codex')) / 'archived_sessions'),
         ('claude', pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR', home / '.claude')) / 'projects'),
         ('pi', pathlib.Path(os.environ.get('PI_CODING_AGENT_SESSION_DIR') or pi_dir / 'sessions').expanduser())]
gemini_home = pathlib.Path(os.environ.get('GEMINI_CLI_HOME') or home).expanduser()
qwen_home = pathlib.Path(os.environ.get('QWEN_RUNTIME_DIR') or os.environ.get('QWEN_HOME') or home / '.qwen').expanduser()
roots += [('gemini', gemini_home / '.gemini/tmp'), ('gemini', gemini_home / '.cache/.gemini/tmp'),
          ('cline', home / '.cline/data/sessions'), ('qwen', qwen_home / 'projects')]
for editor in ['Code', 'Code - Insiders', 'VSCodium', 'Cursor', 'Windsurf']:
    for base in [home / 'Library/Application Support', pathlib.Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config')]:
        roots.append(('roo', base / editor / 'User/globalStorage/rooveterinaryinc.roo-cline/tasks'))
for server in ['.vscode-server', '.vscode-server-insiders']:
    roots.append(('roo', home / server / 'data/User/globalStorage/rooveterinaryinc.roo-cline/tasks'))

def accepts_log(source, name):
    if source == 'cline':
        return name.endswith('.messages.json')
    if source == 'roo':
        return name == 'ui_messages.json'
    return name.endswith('.jsonl') or source == 'gemini' and name.startswith('session-') and name.endswith('.json')

def document_records(source, document):
    if source == 'gemini' and isinstance(document, dict) and isinstance(document.get('sessionId'), str) and isinstance(document.get('messages'), list):
        return document['messages']
    if source == 'cline' and isinstance(document, dict) and type(document.get('version')) is int and document['version'] == 1 and isinstance(document.get('messages'), list):
        return document['messages']
    if source == 'roo' and isinstance(document, list):
        return document
    raise ValueError('Unsupported log document')

seen_files = set()
for source, root in roots:
    if not root.is_dir():
        continue
    for directory, subdirs, files in os.walk(root, followlinks=False):
        for name in files:
            if not accepts_log(source, name):
                continue
            path = pathlib.Path(directory) / name
            try:
                if path.is_symlink() or path.stat().st_mtime < since:
                    continue
                canonical = str(path.resolve())
                if canonical in seen_files:
                    continue
                seen_files.add(canonical)
                emit({'file': digest(path.parent.name if source == 'roo' else canonical), 'source': source})
                with path.open('rb') as handle:
                    if path.suffix == '.json':
                        data = handle.read(32 * 1024 * 1024 + 1)
                        if len(data) > 32 * 1024 * 1024:
                            raise ValueError('Log document exceeds 32 MiB')
                        for raw in document_records(source, json.loads(data)):
                            record = sanitized(source, raw) if isinstance(raw, dict) else None
                            if record:
                                emit({'record': record})
                        emit({'endFile': True})
                        continue
                    while True:
                        line = handle.readline(32 * 1024 * 1024 + 1)
                        if not line:
                            break
                        if len(line) > 32 * 1024 * 1024:
                            ignorable = re.match(rb'^\s*\{\s*(?:"timestamp"\s*:\s*"[^"\\]*"\s*,\s*)?"type"\s*:\s*"(?:response_item|compacted|user|progress|file-history-snapshot)"', line[:1024])
                            while line and not line.endswith(b'\n'):
                                line = handle.readline(32 * 1024 * 1024)
                            if not ignorable:
                                skipped += 1
                            continue
                        if not line.endswith(b'\n'):
                            continue
                        markers = {'pi': [b'"usage"', b'"session"'], 'claude': [b'"usage"'],
                                   'gemini': [b'"tokens"'], 'qwen': [b'"usageMetadata"']}.get(source,
                                   [b'"token_count"', b'"token_usage_record"', b'"turn_context"', b'"session_meta"'])
                        if not any(marker in line for marker in markers):
                            continue
                        try:
                            raw = json.loads(line)
                            record = sanitized(source, raw) if isinstance(raw, dict) else None
                            if record:
                                emit({'record': record})
                        except (ValueError, TypeError):
                            skipped += 1
                emit({'endFile': True})
            except (OSError, ValueError, TypeError):
                skipped += 1

# SQLite must be queried each time: new rows may still be in the WAL.
data_home = pathlib.Path(os.environ.get('XDG_DATA_HOME') or home / '.local/share')
sqlite_files = [('opencode', data_home / 'opencode/opencode.db')]
kilo_dir = data_home / 'kilo'
kilo_override = os.environ.get('KILO_DB')
if kilo_override and kilo_override != ':memory:':
    path = pathlib.Path(kilo_override)
    sqlite_files.append(('kilo', path if path.is_absolute() else kilo_dir / path))
elif not kilo_override and kilo_dir.is_dir():
    sqlite_files += [('kilo', path) for path in sorted(kilo_dir.glob('*.db'))]
for source, path in sqlite_files:
    if not path.is_file() or path.is_symlink():
        continue
    try:
        db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=0.1)
        supported = False
        for table in ['message', 'session_message']:
            try:
                cursor = db.execute('SELECT id,data,time_created FROM ' + table + ' WHERE time_created>=? ORDER BY time_created DESC LIMIT 100001', (since * 1000,))
            except sqlite3.OperationalError:
                continue
            supported = True
            for index, (identity, raw, created) in enumerate(cursor):
                if index == 100000:
                    emit({'notice': source + ': Import auf 100.000 Zeilen je Tabelle begrenzt.'})
                    break
                if len(raw) > 2_000_000:
                    skipped += 1
                    continue
                try:
                    row = json.loads(raw)
                    if (row.get('role') or row.get('type')) != 'assistant':
                        continue
                    tokens = row.get('tokens') or {}
                    cache = tokens.get('cache') or {}
                    values = [tokens.get('input'), tokens.get('output'), tokens.get('reasoning'), cache.get('read'), cache.get('write')]
                    total = sum(max(0, value) for value in values if isinstance(value, (int, float)) and not isinstance(value, bool))
                    timestamp = (row.get('time') or {}).get('created', created) / 1000
                    if not (since <= timestamp <= now) or total <= 0:
                        continue
                    model = row.get('model') or {}
                    emit({'event': {'id': digest(row.get('id') or identity), 'source': source, 'date': timestamp,
                                    'model': row.get('modelID') or model.get('modelID') or model.get('id') or 'Unbekannt',
                                    'provider': row.get('providerID') or model.get('providerID') or model.get('providerId') or 'Unbekannt', 'tokens': total, **({'reportedCost': numbers(row, ['cost']).get('cost')} if source == 'kilo' else {}), 'tokenBreakdown': {**numbers(tokens, ['input', 'output', 'reasoning']), 'cache': numbers(cache, ['read', 'write'])}}})
                except (ValueError, TypeError, AttributeError):
                    skipped += 1
        if not supported:
            emit({'notice': source + ': unbekanntes Datenbankschema.'})
        db.close()
    except (OSError, sqlite3.Error):
        emit({'notice': source + ': Datenbank nicht lesbar.'})
if skipped:
    emit({'notice': str(skipped) + ' Dateien oder Logzeilen wurden übersprungen.'})
emit({'done': True})
