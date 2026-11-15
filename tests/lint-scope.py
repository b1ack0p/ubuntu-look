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
    "DEBIAN_FRONTEND", "UBUNTU_LOOK_LOGGING", "UBUNTU_LOOK_STARTED_MARK", "http_proxy", "https_proxy", "_",
}

# Strip comments and the text of single-quoted strings (awk, sed and JS
# snippets), over the whole script so a string that spans lines is one string.
# Line numbers stay as they are. Returns the lines, and the numbers of the
# function headings found inside a string: there the quotes were misread.
def strip_code(lines):
    text = "\n".join(lines)
    out, lost = [], []
    # The stack holds "code" or "dq"; $( inside a double-quoted string opens
    # code again.
    stack, i, n, line_no = ["code"], 0, len(text), 1
    heading = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\(\) *\{")
    while i < n:
        ch = text[i]
        if ch == "\n":
            line_no += 1
            out.append(ch)
            i += 1
            continue
        if ch == "\\" and i + 1 < n and text[i + 1] != "\n":
            out.append(text[i:i + 2])
            i += 2
            continue
        if stack[-1] == "dq":
            if ch == '"':
                stack.pop()
            elif text.startswith("$(", i) and not text.startswith("$((", i):
                stack.append("code")
                out.append("$(")
                i += 2
                continue
            out.append(ch)
            i += 1
            continue
        if ch == '"':
            stack.append("dq")
        elif ch == "#" and (i == 0 or text[i - 1] in " \t\n;("):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif ch == "'":
            # $'...' takes backslash escapes; '...' takes none.
            ansi = i > 0 and text[i - 1] == "$"
            out.append("'")
            i += 1
            while i < n and text[i] != "'":
                if ansi and text[i] == "\\" and i + 1 < n:
                    i += 1
                if text[i] == "\n":
                    line_no += 1
                    out.append("\n")
                    if heading.match(text, i + 1):
                        lost.append(line_no)
                i += 1
            out.append("'")
            i += 1
            continue
        elif text.startswith("$(", i) and not text.startswith("$((", i):
            stack.append("code")
            out.append("$(")
            i += 2
            continue
        elif ch == ")" and len(stack) > 1:
            stack.pop()
        out.append(ch)
        i += 1
    return "".join(out).split("\n"), lost

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

stripped, lost = strip_code(clean)
if lost:
    # Code after such a line would be checked as text or not at all.
    for n in lost:
        print(f"{path}:{n}: a function starts inside a quoted string: the quotes before it were misread")
    print(f"{len(lost)} scope problem(s): the script could not be read")
    sys.exit(1)

functions, name, top = {}, None, []
for i, (raw, line) in enumerate(zip(clean, stripped), 1):
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) *\{", raw)
    if m:
        name = m.group(1)
        functions[name] = []
    if name:
        functions[name].append((i, line))
    else:
        top.append(line)
    # The function ends at its closing brace: on a line of its own, or on the
    # heading's line when the whole function is written there.
    if line.startswith("}") or (m and line.rstrip().endswith("}")
                                and line.count("{") == line.count("}")):
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
