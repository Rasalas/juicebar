# Sent to Python over SSH stdin. Read-only: no files, packages or credentials are written.
import datetime, hashlib, json, os, pathlib, sqlite3, time, re

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
    return {key: value[key] for key in keys if isinstance(value.get(key), (int, float)) and not isinstance(value.get(key), bool)}

usage_keys = ['input_tokens', 'output_tokens', 'cached_input_tokens', 'cache_write_input_tokens', 'total_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens']

def sanitized(source, row):
    kind = row.get('type')
    timestamp = row.get('timestamp')
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
roots = [('codex', pathlib.Path(os.environ.get('CODEX_HOME', home / '.codex')) / 'sessions'),
         ('codex', pathlib.Path(os.environ.get('CODEX_HOME', home / '.codex')) / 'archived_sessions'),
         ('claude', pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR', home / '.claude')) / 'projects')]
for source, root in roots:
    if not root.is_dir():
        continue
    for directory, subdirs, files in os.walk(root, followlinks=False):
        for name in files:
            if not name.endswith('.jsonl'):
                continue
            path = pathlib.Path(directory) / name
            try:
                if path.is_symlink() or path.stat().st_mtime < since:
                    continue
                emit({'file': digest(str(path)), 'source': source})
                with path.open('rb') as handle:
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
                        markers = [b'"usage"'] if source == 'claude' else [b'"token_count"', b'"token_usage_record"', b'"turn_context"', b'"session_meta"']
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
            except OSError:
                skipped += 1

# OpenCode's two schemas may coexist. Swift deduplicates their stable message IDs.
path = pathlib.Path(os.environ.get('XDG_DATA_HOME', home / '.local/share')) / 'opencode/opencode.db'
if path.is_file():
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
                    emit({'notice': 'OpenCode: Import auf 100.000 Zeilen je Tabelle begrenzt.'})
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
                    emit({'event': {'id': digest(row.get('id') or identity), 'source': 'opencode', 'date': timestamp,
                                    'model': row.get('modelID') or model.get('modelID') or model.get('id') or 'Unbekannt',
                                    'provider': row.get('providerID') or model.get('providerID') or model.get('providerId') or 'Unbekannt', 'tokens': total, 'tokenBreakdown': {**numbers(tokens, ['input', 'output', 'reasoning']), 'cache': numbers(cache, ['read', 'write'])}}})
                except (ValueError, TypeError, AttributeError):
                    skipped += 1
        if not supported:
            emit({'notice': 'OpenCode: unbekanntes Datenbankschema.'})
        db.close()
    except (OSError, sqlite3.Error):
        emit({'notice': 'OpenCode-Datenbank nicht lesbar.'})
if skipped:
    emit({'notice': str(skipped) + ' Dateien oder Logzeilen wurden übersprungen.'})
emit({'done': True})
