#!/usr/bin/env python3
"""Scope check for ubuntu-look.sh.

Rule 1: a lowercase variable that a function assigns is declared 'local' there,
        or is declared at the top level (the 'packages' table).
Rule 2: an UPPERCASE variable that a function assigns is declared in section 1
        (constants and run state) or set by init_run / init_options.
Variables of the commands' environment (LC_ALL, IFS, ...) are exempt.
Exits 1 and lists the offenders when a rule is broken.
usage: lint-scope.py <script>
"""
import re
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")

# Blank out here-document bodies: they hold other languages.
clean, end = [], None
for line in lines:
    if end is not None:
        if line.strip() == end:
            end = None
        clean.append("")
        continue
    m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
    if m and "<<<" not in line:
        end = m.group(2)
    clean.append(line)

# Variables that belong to the environment of the commands the script runs.
ENVIRONMENT = {
    "LC_ALL", "IFS", "DCONF_PROFILE", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR",
    "DEBIAN_FRONTEND", "UBUNTU_LOOK_LOGGING", "http_proxy", "https_proxy", "_",
}

# Strip comments and single-quoted strings (awk, sed and JS snippets).
def code(line):
    line = re.sub(r"'[^']*'", "''", line)
    return re.sub(r"(^|\s)#.*$", "", line)

# Drop the text of double-quoted strings, keeping command substitutions.
def unquote(text):
    out, i, depth, quoted = [], 0, 0, [False]
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            if not quoted[-1]:
                out.append(text[i:i + 2])
            i += 2
            continue
        if ch == '"':
            quoted[-1] = not quoted[-1]
        elif text.startswith("$(", i) and not text.startswith("$((", i):
            quoted.append(False)
            out.append(" ; ")
            i += 2
            continue
        elif ch == ")" and len(quoted) > 1 and not quoted[-1]:
            quoted.pop()
            out.append(" ; ")
        elif not quoted[-1]:
            out.append(ch)
        i += 1
    return "".join(out)

functions, name, top = {}, None, []
for i, raw in enumerate(clean, 1):
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) *\{", raw)
    if m:
        name = m.group(1)
        functions[name] = []
    if name:
        functions[name].append((i, code(raw)))
    else:
        top.append(code(raw))
    if raw.startswith("}"):
        name = None

NAME = r"[A-Za-z_][A-Za-z0-9_]*"
START = r"(?:^|[;&|({]|\bthen\b|\bdo\b|\belse\b|\bexport\b|\breadonly\b)\s*"

def assigned(text):
    text = unquote(text)
    # VAR=value in front of a command sets that command's environment only.
    text = re.sub(r"(?:\b" + NAME + r"=[^\s;|&]*[ \t]+)+(?=[a-z./][\w./-]*(?:[ \t]|$))", "", text, flags=re.M)
    found = set(re.findall(START + r"(" + NAME + r")(?:\[[^\]]*\])?\+?=", text, re.M))
    found |= set(re.findall(r"\bfor\s+(" + NAME + r")\s+in\b", text))
    found |= set(re.findall(r"\bfor\s+\(\(\s*(" + NAME + r")\s*=", text))
    found |= set(re.findall(r"\bprintf\s+-v\s+(" + NAME + r")", text))
    found |= set(re.findall(r"\b(?:mapfile|readarray)\s+(?:-\S+\s+)*(" + NAME + r")\s*(?:<|$)", text, re.M))
    for m in re.finditer(r"\bread[ \t]+((?:-\S+(?:[ \t]+[0-9.]+)?[ \t]+)*)((?:" + NAME + r"[ \t]*)+)", text):
        found |= set(m.group(2).split())
    return found - ENVIRONMENT

def declared_local(text):
    names = set()
    for m in re.finditer(r"\blocal\s+((?:-[A-Za-z]+\s+)*)([^\n;]*)", text):
        rest = re.sub(r'"[^"]*"|\$\([^)]*\)|\$\{[^}]*\}', "", m.group(2))
        names |= set(re.findall(r"(" + NAME + r")(?:=|\s|$)", rest))
    return names

top_text = "\n".join(top)
state = assigned(top_text) | set(re.findall(r"\bdeclare\s+(?:-\S+\s+)*(" + NAME + r")", top_text))
for init in ("init_run", "init_options"):
    text = "\n".join(c for _, c in functions.get(init, []))
    state |= {v for v in assigned(text) if v.upper() == v}

problems = []
for fn, body in functions.items():
    text = "\n".join(c for _, c in body)
    local = declared_local(text)
    for var in sorted(assigned(text) - local):
        line = next((n for n, c in body if re.search(r"\b" + var + r"\b", c)), body[0][0])
        if var in state:
            continue
        if var.upper() != var:
            problems.append(f"{path}:{line}: {fn}: '{var}' is assigned but not declared local")
        elif fn not in ("init_run", "init_options"):
            problems.append(f"{path}:{line}: {fn}: '{var}' is not declared in section 1")

for p in problems:
    print(p)
print(f"{len(problems)} scope problem(s) in {len(functions)} functions")
sys.exit(1 if problems else 0)
