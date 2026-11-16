#!/usr/bin/env python3
"""Offline instrument-artwork audit for installed Garritan bank XML files.

Run: python3 scripts/audit_instrument_artwork.py [--output report.json] [bank.xml ...]
Without paths, searches Studio's GPO5/Instant Orchestra default install paths.
This is a conservative name-based audit, not the application's definitive Swift resolver.
"""
import argparse
import collections
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

DEFAULT_BANKS = [
    "/Library/Application Support/Garritan/Garritan Personal Orchestra 5/Banks/Standard/Personal Orchestra 5.bank.xml",
    "/Library/Application Support/Garritan/Garritan Personal Orchestra 5/Banks/Notation/Personal Orchestra 5.bank.xml",
    "/Library/Application Support/Garritan/Garritan Instant Orchestra/Banks/Standard/Instant Orchestra.bank.xml",
]
# Specific-to-general ordering matters; don't collapse a bass clarinet into a bass.
RULES = [
    ("woodwind.clarinet.contrabass", r"contrabass ?clarinet"),
    ("woodwind.clarinet.bass", r"bass clarinet"),
    ("woodwind.clarinet.alto", r"alto clarinet"),
    ("woodwind.clarinet.eb", r"(?:e[- ]?flat|e♭|eb) clarinet"),
    ("woodwind.clarinet.bb", r"(?:b[- ]?flat|b♭|bb) clarinet|clarinet in (?:bb|b[- ]?flat)"),
    ("woodwind.clarinet.a", r"a clarinet|clarinet in a"),
    ("woodwind.clarinet", r"clarinet"),
    ("woodwind.flute.alto", r"alto flute"),
    ("woodwind.flute.bass", r"bass flute"),
    ("brass.trumpet.piccolo", r"piccolo trumpet"),
    ("woodwind.piccolo", r"piccolo"),
    ("woodwind.flute", r"flute"),
    ("woodwind.english_horn", r"english horn|cor anglais"),
    ("woodwind.oboe", r"oboe"),
    ("woodwind.contrabassoon", r"contrabassoon|contra bassoon"),
    ("woodwind.bassoon", r"bassoon"),
    ("woodwind.sax.bass", r"bass sax(?:ophone)?"),
    ("woodwind.sax.baritone", r"(?:baritone|bari) sax(?:ophone)?"),
    ("woodwind.sax.tenor", r"tenor sax(?:ophone)?"),
    ("woodwind.sax.alto", r"alto sax(?:ophone)?"),
    ("woodwind.sax.soprano", r"soprano sax(?:ophone)?"),
    ("brass.trombone.contrabass", r"contra(?:bass| bass) trombone"),
    ("brass.trombone.bass", r"bass trombone"),
    ("brass.trombone.alto", r"alto trombone"),
    ("brass.trombone", r"trombone"),
    ("brass.euphonium", r"euphonium"),
    ("brass.baritone_horn", r"baritone horn"),
    ("brass.tuba", r"tuba"),
    ("brass.flugelhorn", r"flugel ?horn|flügelhorn"),
    ("brass.cornet", r"cornet"),
    ("brass.trumpet", r"trumpet"),
    ("brass.horn", r"french horn|sam horn|horn section|horns? [1-9]"),
    ("percussion.timpani", r"timpani|kettle drum"),
    ("percussion.snare.field", r"marching snare|field snare|field drum|parade snare"),
    ("percussion.marching.tenors", r"marching tenors|tenor drums|tenor quads|marching quads|quad toms"),
    ("percussion.drumkit", r"drum ?kit|drumset|drum set|trap set"),
    ("percussion.drumkit.kick", r"kick drum|kick pedal|kick 808"),
    ("percussion.drumkit.rack_tom", r"rack tom|high tom|mid tom|mounted tom"),
    ("percussion.drumkit.floor_tom", r"floor tom|low tom"),
    ("percussion.snare", r"snares?|side drum"),
    ("percussion.bass_drum", r"bass drum|gran cassa"),
    ("percussion.crotales", r"crotales?"),
    ("percussion.glockenspiel", r"glockenspiel"),
    ("percussion.xylophone", r"xylophone"),
    ("percussion.vibraphone", r"vibraphone"),
    ("percussion.marimba", r"marimba"),
    ("percussion.handbells", r"handbells?"),
    ("percussion.tubular_bells", r"tubular bells?|chimes"),
    ("percussion.cymbals.hihat", r"hi[- ]?hat"),
    ("percussion.cymbals.ride", r"ride cymbal|ride bell"),
    ("percussion.cymbals.crash", r"crash cymbal|hand cymbal|clash cymbal"),
    ("percussion.cymbals.suspended", r"suspended cymbal|suspended crash"),
    ("percussion.cymbals", r"cymbals?"),
    ("percussion.gong", r"gong|tam[- ]?tam"),
    ("percussion.anvil", r"anvil"),
    ("percussion.slapstick", r"slapstick|slap stick|whip percussion"),
    ("percussion.triangle", r"triangle"),
    ("percussion.tambourine", r"tambourine"),
    ("strings.violin", r"violins?|fiddle"),
    ("strings.viola", r"violas?"),
    ("strings.cello", r"cellos?|violoncello"),
    ("strings.double_bass", r"double bass|basses|contrabass"),
    ("strings.harp", r"harp"),
    ("keyboard.harpsichord", r"harpsichord"),
    ("keyboard.celesta", r"celesta|celeste"),
    ("keyboard.piano", r"piano|steinway"),
    ("keyboard.organ", r"organ"),
    ("vocal.choir", r"choir|sopranos?|altos?|tenors?|children|boys"),
]
PATTERNS = [(key, re.compile(r"(?<![a-z])(?:" + regex + r")(?![a-z])", re.I)) for key, regex in RULES]
GENERIC = re.compile(r"\b(?:section|ensemble|full strings|percussion accessories|orchestra|brass|winds|world|synth)\b", re.I)
PROGRAM_TAGS = {"program", "instrument", "patch", "preset"}
NAME_KEYS = ("name", "displayname", "label", "title")

def names_from_bank(path):
    root = ET.parse(path).getroot()
    found = []
    for node in root.iter():
        tag = node.tag.rsplit("}", 1)[-1].lower()
        if tag not in PROGRAM_TAGS:
            continue
        attrs = {k.lower(): v for k, v in node.attrib.items()}
        name = next((attrs[k].strip() for k in NAME_KEYS if attrs.get(k, "").strip()), None)
        if not name:
            for child in node:
                key = child.tag.rsplit("}", 1)[-1].lower()
                if key in NAME_KEYS and child.text and child.text.strip():
                    name = child.text.strip()
                    break
        if name:
            found.append(name)
    return list(dict.fromkeys(found))

def classify(name):
    hits = [key for key, pattern in PATTERNS if pattern.search(name)]
    if not hits:
        return {"status": "generic" if GENERIC.search(name) else "unmapped", "identity": None}
    if len(hits) > 1:
        # Explicit priority is used for the candidate, but overlaps need review.
        return {"status": "review_overlap", "identity": hits[0], "other_matches": hits[1:]}
    return {"status": "candidate", "identity": hits[0]}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("banks", nargs="*", help="Paths to installed *.bank.xml files")
    parser.add_argument("--output", default="instrument-artwork-audit.json")
    args = parser.parse_args()
    report = {"scope": "name-based candidates, NOT confirmed artwork assignments", "banks": [], "summary": {}}
    rows = []
    for raw in args.banks or DEFAULT_BANKS:
        path = Path(raw)
        if not path.is_file():
            report["banks"].append({"path": str(path), "status": "not_installed"})
            continue
        try:
            names = names_from_bank(path)
        except (ET.ParseError, OSError) as error:
            report["banks"].append({"path": str(path), "status": "parse_error", "error": str(error)})
            continue
        report["banks"].append({"path": str(path), "status": "read", "programs_found": len(names)})
        for name in names:
            rows.append({"bank": str(path), "program": name, **classify(name)})
    report["programs"] = rows
    report["summary"] = dict(collections.Counter(row["status"] for row in rows))
    Path(args.output).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"banks": report["banks"], "summary": report["summary"], "report": args.output}, indent=2))

if __name__ == "__main__":
    main()
