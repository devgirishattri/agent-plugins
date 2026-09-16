"""Shared lexical query grammar; memory scoring remains in memory-search.sh."""
import re

TOKEN_RE = re.compile(r"[^a-z0-9]+")


def tokenize(s):
    return [t for t in TOKEN_RE.split(s.lower()) if t]

def parse_query(raw):
    i, n = 0, len(raw)
    raw_atoms = []
    while i < n:
        while i < n and raw[i].isspace():
            i += 1
        if i >= n:
            break
        if raw[i] == '"':
            j = raw.find('"', i + 1)
            if j == -1:
                return None
            raw_atoms.append(("phrase", raw[i + 1:j]))
            i = j + 1
            continue
        j = i
        while j < n and not raw[j].isspace():
            j += 1
        raw_atoms.append(("term", raw[i:j]))
        i = j

    atoms = []
    for kind, text in raw_atoms:
        if kind == "phrase":
            toks = tokenize(text)
            if not toks:
                continue
            atoms.append(("phrase", " ".join(toks), False))
        else:
            prefix = False
            t = text
            if t == "*":
                continue
            if t.endswith("*") and len(t) > 1:
                prefix = True
                t = t[:-1]
            toks = tokenize(t)
            if not toks:
                continue
            for tok in toks[:-1]:
                atoms.append(("term", tok, False))
            atoms.append(("term", toks[-1], prefix))

    seen = set()
    deduped = []
    for a in atoms:
        if a not in seen:
            seen.add(a)
            deduped.append(a)
    return deduped


def atom_matches(atom, field_tokens, field_joined):
    kind = atom[0]
    if kind == "term":
        _, value, prefix = atom
        if prefix:
            return any(tok.startswith(value) for tok in field_tokens)
        return value in field_tokens
    _, value, _ = atom
    if not value:
        return False
    return value in field_joined

