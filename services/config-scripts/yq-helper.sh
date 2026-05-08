#!/bin/bash

# yq-helper.sh: Provides a robust way to parse YAML using yq if available,
# or python3 + PyYAML as a fallback.

if command -v yq >/dev/null 2>&1; then
    yq "$@"
else
    # Fallback to python3
    python3 -c "
import sys
import yaml

def get_val(data, path):
    if not path or path == '.': return data
    parts = path.strip('.').split('.')
    for part in parts:
        if not part: continue
        if '[' in part:
            name, idx = part.split('[')
            idx = int(idx.rstrip(']'))
            data = data[name][idx]
        else:
            if isinstance(data, dict):
                data = data.get(part)
            else:
                return None
        if data is None: return None
    return data

def format_val(val):
    if val is None: return ''
    if isinstance(val, (list, dict)):
        return yaml.dump(val, default_flow_style=False).strip()
    return str(val)

try:
    # Very basic yq emulation for the needs of this project
    args = sys.argv[1:]
    if not args: sys.exit(0)
    
    # Handle 'eval' or just query
    if args[0] == 'eval':
        query = args[1]
        file = args[2]
    elif args[0] == '-e':
        query = args[1]
        file = args[2]
    elif args[0].startswith('.'):
        query = args[0]
        file = args[1]
    else:
        sys.exit(1)

    with open(file) as f:
        data = yaml.safe_load(f)

    if '[]' in query:
        base, rest = query.split('[]')
        items = get_val(data, base)
        if items:
            for item in items:
                v = get_val(item, rest)
                if v is not None: print(format_val(v))
    else:
        v = get_val(data, query)
        if v is not None: print(format_val(v))
except Exception as e:
    # print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" "$@"
fi
