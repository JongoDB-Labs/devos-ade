#!/usr/bin/env python3
"""What dc (lib/common.sh) may call after its .env snapshot, and whether any of it writes .env.

dc takes a snapshot of .env (_env_snap) once localgit_sso_ensure has run, and get_env reads keys from it for the rest
of the call. set_env, set_env_batch and unset_env drop the snapshot, but only in the shell they run in: one run in a
subshell of dc ($(...), a pipe) would leave dc reading the old value. So nothing dc calls after the snapshot may write
.env. This reads every function of lib/*.sh, follows the calls from the text of dc after `_env_snap` (any word that
is a function's name counts as a call, comments aside: it errs on the side of more calls), and prints each function
reached that calls set_env, set_env_batch or unset_env, or redirects or moves a file onto "$ENV_FILE", with the path
that reaches it. Status 1 when there is one.

Usage: tests/dc_env_writers.py [--root DIR]
"""
import glob
import os
import re
import sys

WRITES = re.compile(r'(?<![\w-])(set_env|set_env_batch|unset_env)(?![\w-])|>>?\s*"\$ENV_FILE"|\bmv\b[^\n]*"\$ENV_FILE"')
DEF = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{(.*)$')


def functions(root):
    out = {}
    for path in sorted(glob.glob(os.path.join(root, 'lib', '*.sh'))):
        name, body = None, []
        with open(path, errors='replace') as f:
            for line in f:
                m = DEF.match(line)
                if m and name is None:
                    name, body = m.group(1), [m.group(2) + '\n']
                    rest = m.group(2).rstrip()
                    if rest.endswith('}') and rest.count('{') < rest.count('}'):   # a one-line function
                        out[name] = ''.join(body); name = None
                    continue
                if name is not None:
                    body.append(line)
                    if line.startswith('}'):
                        out[name] = ''.join(body); name = None
    return out


def code(text):
    return re.sub(r'(^|\s)#[^\n]*', r'\1', text)   # (comments out; a # inside a word, as in ${#a[@]}, stays)


def main():
    root = '.'
    if len(sys.argv) > 2 and sys.argv[1] == '--root':
        root = sys.argv[2]
    fns = functions(root)
    if 'dc' not in fns or '_env_snap' not in fns['dc']:
        print('dc_env_writers: no dc, or no _env_snap in it', file=sys.stderr)
        return 2
    names = set(fns)
    word = {n: re.compile(r'(?<![\w-])' + re.escape(n) + r'(?![\w-])') for n in names}
    after = code(fns['dc'][fns['dc'].index('_env_snap'):])
    start = sorted(n for n in names if n not in ('dc', '_env_snap') and word[n].search(after))
    path = {n: ['dc', n] for n in start}
    todo, seen = list(start), set()
    while todo:
        x = todo.pop()
        if x in seen:
            continue
        seen.add(x)
        body = code(fns[x])
        for y in names:
            if y != x and y not in seen and word[y].search(body):
                path.setdefault(y, path[x] + [y])
                todo.append(y)
    bad = sorted(n for n in seen if WRITES.search(code(fns[n])))
    for n in bad:
        print('writes .env under dc: ' + ' -> '.join(path[n]))
    print('%d functions reached from dc after its snapshot, %d write .env' % (len(seen), len(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
