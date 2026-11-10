#!/usr/bin/env python3
"""AlgoApp deck → Gist It card file (JSON, "gist-it-cards" v1 — see Domain/Entities/CardFile.swift).

Usage: tools/algoapp_to_cards.py <deck.zip | deck.xml> [out.json]

The deck's Front becomes the expression; the Back's lines are sorted into fields: the first line is
the translation; "Example:" or the first English sentence is the example; "Synonyms:" or an English
"a / b / c" list are the synonyms; Russian notes, example translations and extra examples go to the
context. Repeated expressions (case, apostrophes and end punctuation ignored) are merged into the
fullest card, filling its missing example / synonyms from the others. Images are not carried over.
Import the result in the app: Study → In flashcards → Import cards.
"""
import re, html, json, sys, collections, datetime, zipfile, os
import xml.etree.ElementTree as ET

src = sys.argv[1]
dst = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(src)[0] + '.json'
if src.endswith('.zip'):
    with zipfile.ZipFile(src) as z:
        xml_name = next(n for n in z.namelist() if n.endswith('.xml'))
        xml_bytes = z.read(xml_name)
    deck_name = os.path.splitext(os.path.basename(xml_name))[0]
else:
    xml_bytes = open(src, 'rb').read()
    deck_name = os.path.splitext(os.path.basename(src))[0]
CYR = re.compile('[А-Яа-яЁё]'); LAT = re.compile('[A-Za-z]')

def lines_of(rich):
    s = rich or ""
    s = re.sub(r'(?i)<br\s*/?>', '\n', s)
    s = re.sub(r'(?i)</(p|div|li|h\d)\s*>', '\n', s)
    s = re.sub(r'<[^>]+>', '', s)
    s = html.unescape(s).replace('\xa0', ' ')
    return [l for l in (re.sub(r'\s+', ' ', x).strip() for x in s.split('\n')) if l]

def kind(l):
    c, a = bool(CYR.search(l)), bool(LAT.search(l))
    return 'mixed' if c and a else ('cyr' if c else ('lat' if a else 'other'))

def is_sentence(l):
    return bool(re.search(r'[.!?…]["”’)]?$', l)) or len(l.split()) > 12

def split_synonyms(l):
    parts = re.split(r'\s*/\s*', l) if '/' in l else re.split(r'\s*,\s*', l)
    return [p.strip(' .;') for p in parts if p.strip(' .;')]

def strip_prefix(l, names):
    m = re.match(r'(?i)^\s*(?:' + '|'.join(names) + r')\s*[:：]\s*', l)
    return (l[m.end():].strip(), True) if m else (l, False)

stats = collections.Counter()
def convert(front, back):
    junk = re.compile(r'(?i)^vocab cards\b')
    front = [l for l in front if not junk.match(l)]
    if not front: stats['skipped: empty front'] += 1; return None
    expression, context = front[0], front[1:]
    translation, example, synonyms = (back[0] if back else ''), '', []
    rest = []
    # Pass 1: labelled lines win (Example: / Synonyms: / Meaning:), wherever they are.
    for raw in back[1:]:
        l = raw.lstrip('•-– ').strip() if raw.lstrip().startswith(('•', '- ', '– ')) else raw
        text, ex = strip_prefix(l, ['example', 'e\\.g\\.'])
        if ex and not example and kind(text) != 'cyr':
            example = text; continue
        text, sy = strip_prefix(l, ['synonyms?', 'синонимы?'])
        if sy and not synonyms:
            synonyms = split_synonyms(text); continue
        _, note = strip_prefix(l, ['meaning', 'note', 'значение', 'пример', 'перевод'])
        if note or ex or sy:
            context.append(raw); continue
        rest.append((raw, l))
    # Pass 2: unlabelled lines by language and shape.
    for raw, l in rest:
        k = kind(l)
        if k == 'lat':
            if not synonyms and '/' in l and not is_sentence(l): synonyms = split_synonyms(l)
            elif not example: example = l
            else: context.append(raw)
        elif k == 'mixed' and not example and re.search(r'\s[—–-]\s', l):
            left, right = re.split(r'\s[—–-]\s', l, maxsplit=1)
            if kind(left) == 'lat': example = left.strip(); context.append(right.strip())
            else: context.append(raw)
        else:
            context.append(raw)
    # No line twice, and nothing that already is another field.
    taken = {x.lower() for x in (expression, translation, example) if x}
    unique = []
    for line in context:
        if line.lower() not in taken: unique.append(line); taken.add(line.lower())
    context = unique
    return {'expression': expression, 'translation': translation, 'example': example,
            'synonyms': synonyms, 'context': '\n'.join(context)}

def key(e):
    k = e.lower().replace('’', "'").replace('‘', "'")
    return re.sub(r'\s+', ' ', k).strip().rstrip('.!?')

root = ET.fromstring(xml_bytes)
cards, order = {}, []
for c in root.iter('card'):
    f = {rt.get('name'): rt.text for rt in c.findall('rich-text')}
    card = convert(lines_of(f.get('Front')), lines_of(f.get('Back')))
    if not card: continue
    k = key(card['expression'])
    if k not in cards: cards[k] = [card]; order.append(k)
    else: cards[k].append(card); stats['merged duplicates'] += 1

def score(c): return (sum(bool(c[x]) for x in ('translation', 'example', 'synonyms', 'context')), len(json.dumps(c, ensure_ascii=False)))
out = []
for k in order:
    group = cards[k]
    base = dict(max(group, key=score))
    for other in group:
        if not base['example'] and other['example']: base['example'] = other['example']
        if not base['synonyms'] and other['synonyms']: base['synonyms'] = other['synonyms']
    base = {k2: v for k2, v in base.items() if v}  # omit empty optional fields
    out.append(base)
    stats['cards'] += 1
    for f in ('example', 'synonyms', 'context'): stats['with ' + f] += f in base

doc = {'format': 'gist-it-cards', 'version': 1,
       'exportedAt': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
       'source': 'AlgoApp deck ' + deck_name, 'cards': out}
json.dump(doc, open(dst, 'w'), ensure_ascii=False, indent=1)
for k, v in sorted(stats.items()): print(f'{k}: {v}')
print('written:', dst)
