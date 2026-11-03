#!/usr/bin/env python3
"""Adds a release to Sparkle's appcast.xml (creating it if needed), newest first.

  tools/appcast.py <appcast.xml> <version> <build> <zip url> <notes url> '<sparkle:edSignature="…" length="…">'

The last argument is sign_update's output. An existing item with the same build is replaced; older
items are kept (their per-tag download URLs stay valid), capped at MAX_ITEMS.
"""
import re
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MIN_SYSTEM = "26.0"
MAX_ITEMS = 10
ET.register_namespace("sparkle", SPARKLE)
S = lambda tag: f"{{{SPARKLE}}}{tag}"

path, version, build, zip_url, notes_url, signed = sys.argv[1:7]
attrs = dict(re.findall(r'([\w:]+)="([^"]*)"', signed))
signature, length = attrs.get("sparkle:edSignature"), attrs.get("length")
if not signature or not length:
    sys.exit(f"Couldn't read the signature from sign_update output: {signed!r}")

try:
    tree = ET.parse(path)
    channel = tree.getroot().find("channel")
except (FileNotFoundError, ET.ParseError):
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Standard Music"
    tree = ET.ElementTree(root)

for old in channel.findall("item"):
    if old.findtext(S("version")) == build:
        channel.remove(old)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Standard Music {version}"
ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
ET.SubElement(item, S("version")).text = build
ET.SubElement(item, S("shortVersionString")).text = version
ET.SubElement(item, S("minimumSystemVersion")).text = MIN_SYSTEM
ET.SubElement(item, S("releaseNotesLink")).text = notes_url
ET.SubElement(item, "enclosure", {
    "url": zip_url,
    "type": "application/octet-stream",
    S("edSignature"): signature,
    "length": length,
})
children = list(channel)
first_item = next((i for i, c in enumerate(children) if c.tag == "item"), len(children))
channel.insert(first_item, item)
for extra in channel.findall("item")[MAX_ITEMS:]:
    channel.remove(extra)

ET.indent(tree, "  ")
tree.write(path, encoding="utf-8", xml_declaration=True)
