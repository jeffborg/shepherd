#!/usr/bin/env python3
"""Check references/channel_list against YourTV's live channel lineups.

Shepherd matches a grabber's channel names to the user's subscribed channels
through Shepherd::Common::translate_channel_name plus the per-region lists in
references/channel_list. When a broadcaster renames a channel, that match
silently fails and the channel just stops appearing -- which is how upstream
accumulated issues like "10 peach and 10 bold no longer populating".

This reimplements the same matching rules and reports the drift, so CI catches
a rename within a day instead of a user noticing months later.

Shepherd's region ids are YourTV's region ids (verified: 184 -> NBN/Newcastle,
73/94/75/101 -> metro), so the region number is used directly.

    util/check_channel_map.py                  # every region with a channel list
    util/check_channel_map.py --region 184     # just one
    util/check_channel_map.py --region 184 --fix   # rewrite that region's line
    util/check_channel_map.py --check-regions  # verify the xmltvnet region map
    util/check_channel_map.py --region 184 --dump-channels-conf '{id}.yourtv.au'
                                               # a channels.conf with chosen xmltv_ids

Exit status is 1 if any checked region has YourTV channels that Shepherd would
fail to match, which is the condition worth failing a build over. Channels
Shepherd lists but YourTV no longer carries are reported but not fatal: they
may be legitimately off-air rather than renamed.
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANNEL_LIST = ROOT / "references" / "channel_list"
COMMON_PM = ROOT / "references" / "Shepherd" / "Common.pm"
XMLTVNET = ROOT / "grabbers" / "xmltvnet"

API = "https://www.yourtv.com.au/api"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/120.0 Safari/537.36")


def fetch_json(path):
    req = urllib.request.Request(
        f"{API}/{path}", headers={"User-Agent": UA, "Accept": "application/json"})
    try:
        resp = urllib.request.urlopen(req, timeout=60)
    except urllib.error.URLError as exc:
        raise SystemExit(f"{path}: {exc}") from None
    with resp:
        if "json" not in resp.headers.get("Content-Type", ""):
            raise SystemExit(f"{path}: expected JSON (unknown region, or the API moved)")
        return json.load(resp)


def yourtv_channels(region):
    """Live channel names for a region, deduplicated, order preserved.

    YourTV reuses one display name for SD/HD pairs (Newcastle has two called
    "7"), which Shepherd's name-keyed config cannot represent -- so the
    duplicates collapse here too, deliberately.
    """
    seen, out = set(), []
    for c in fetch_json(f"regions/{region}/channels"):
        name = (c.get("name") or "").strip()
        if name and name not in seen:
            seen.add(name)
            out.append(name)
    return out


def parse_channel_list():
    """-> ({region: [channels]}, [(regions_or_star, from, to)], {duplicate regions})"""
    lists, renames, duplicates = {}, [], set()
    for line in CHANNEL_LIST.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.rstrip("\r")
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, payload = line.split(":", 1)
        if "->" in payload:
            src, dst = payload.split("->", 1)
            renames.append((key, src.strip(), dst.strip()))
        elif re.fullmatch(r"\d+", key):
            if key in lists:
                duplicates.add(key)
                continue   # Shepherd reads the first line only
            lists[key] = [c.strip() for c in payload.split(",") if c.strip()]
    return lists, renames, duplicates


def parse_static_remaps():
    """The $rchans table inside translate_channel_name."""
    src = COMMON_PM.read_text(encoding="utf-8", errors="replace")
    block = re.search(r"\$rchans\s*=\s*\{(.*?)\};", src, re.S)
    if not block:
        raise SystemExit("could not find the $rchans table in Common.pm")
    return dict(re.findall(r"'([^']*)'\s*=>\s*'([^']*)'", block.group(1)))


def translate(name, channels, remaps):
    """Mirror of Shepherd::Common::translate_channel_name."""
    if name in channels:
        return name
    if name in remaps:
        return remaps[name]
    for configured in channels:
        if name.lower() == configured.lower():
            return configured
    if name == "7":
        return "Seven"
    if name == "9":
        return "Nine"
    if name == "10 HD" and "10HD" in channels:
        return "10HD"
    if name == "10HD" and "10 HD" in channels:
        return "10 HD"
    return name


def check_region(region, channels, remaps):
    live = yourtv_channels(region)
    cset = set(channels)
    unmatched = [n for n in live if translate(n, cset, remaps) not in cset]
    resolved = {translate(n, cset, remaps) for n in live}
    stale = [c for c in channels if c not in resolved]
    return live, unmatched, stale


def rewrite_region(region, live, channels, remaps):
    """Keep Shepherd's existing name where it matches, else adopt YourTV's."""
    cset = set(channels)
    out, seen = [], set()
    for n in live:
        name = translate(n, cset, remaps)
        if name not in seen:
            seen.add(name)
            out.append(name)
    new_line = f"{region}:" + ",".join(out)
    lines = CHANNEL_LIST.read_text(encoding="utf-8", errors="replace").splitlines()
    kept, replaced = [], False
    for line in lines:
        if re.fullmatch(rf"{region}:.*", line.rstrip("\r")):
            # Keep the first, drop any duplicates -- Shepherd never reads them.
            if not replaced:
                kept.append(new_line)
                replaced = True
            continue
        kept.append(line)
    if not replaced:
        raise LookupError(f"no '{region}:' line to rewrite")
    CHANNEL_LIST.write_text("\n".join(kept) + "\n", encoding="utf-8")
    return out


def dump_channels_conf(region, channels, remaps, fmt):
    """Emit a Shepherd channels.conf with caller-chosen xmltv_ids.

    Shepherd normally derives xmltv_ids from MythTV or generates them, which
    makes them local to one install. A consumer that merges Shepherd's output
    with another source needs both to agree on channel ids, and the id both
    sides can agree on is YourTV's -- so this maps Shepherd's channel names to
    ids built from the YourTV channel id ({id}) or name ({name}).

    Keys are the names Shepherd itself uses, resolved through the same
    translation the grabbers apply, so this stays correct as names drift.
    """
    cset = set(channels)
    out = {}
    for c in fetch_json(f"regions/{region}/channels"):
        cid, name = str(c.get("id") or ""), (c.get("name") or "").strip()
        if not cid or not name:
            continue
        shep = translate(name, cset, remaps)
        if shep not in cset or shep in out:
            continue   # unknown to this region, or an SD/HD pair sharing a name
        out[shep] = fmt.format(id=cid, name=shep)

    print("$channels = {")
    print(",\n".join(f"  '{k}' => '{v}'" for k, v in sorted(out.items())))
    print("};")
    print("$opt_channels = {};")
    print(f"# {len(out)} channels for region {region}", file=sys.stderr)
    return 0


def check_region_map():
    """Every region with a channel list should be reachable by the xmltvnet grabber."""
    src = XMLTVNET.read_text(encoding="utf-8", errors="replace")
    block = re.search(r"%REGION_FILE\s*=\s*\((.*?)\n\);", src, re.S)
    if not block:
        raise SystemExit("could not find %REGION_FILE in grabbers/xmltvnet")
    mapped = {r for r, _ in re.findall(r"(\d+)\s*=>\s*'([^']+)'", block.group(1))}
    lists, _, _ = parse_channel_list()
    missing = sorted(set(lists) - mapped, key=int)
    print(f"channel_list regions: {len(lists)}   xmltvnet region map: {len(mapped)}")
    if missing:
        print(f"regions with no xmltvnet source file: {' '.join(missing)}")
        return 1
    print("every region with a channel list has an xmltvnet source file")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region", action="append", type=int,
                    help="check only this region (repeatable)")
    ap.add_argument("--fix", action="store_true",
                    help="rewrite the checked region lines from YourTV")
    ap.add_argument("--check-regions", action="store_true",
                    help="verify the xmltvnet region map covers every region")
    ap.add_argument("--dump-channels-conf", metavar="FORMAT",
                    help="write a channels.conf to stdout, xmltv_ids built from "
                         "FORMAT (e.g. '{id}.yourtv.au'); needs --region")
    args = ap.parse_args()

    if args.check_regions:
        return check_region_map()

    lists, renames, duplicates = parse_channel_list()
    remaps = parse_static_remaps()

    if args.dump_channels_conf:
        if not args.region or len(args.region) != 1:
            raise SystemExit("--dump-channels-conf needs exactly one --region")
        region = str(args.region[0])
        if region not in lists:
            raise SystemExit(f"region {region} has no channel list")
        return dump_channels_conf(region, lists[region], remaps,
                                  args.dump_channels_conf)

    if duplicates:
        print("unreachable duplicate region lines (Shepherd reads the first only): "
              + " ".join(sorted(duplicates, key=int)) + "\n")
    regions = [str(r) for r in args.region] if args.region else sorted(lists, key=int)

    drift = 0
    for region in regions:
        channels = lists.get(region)
        if channels is None:
            print(f"region {region}: NO channel list in references/channel_list")
            drift += 1
            continue
        live, unmatched, stale = check_region(region, channels, remaps)
        status = "ok" if not unmatched else f"{len(unmatched)} UNMATCHED"
        print(f"region {region:>4}: {len(live):>2} on YourTV, "
              f"{len(channels):>2} in channel_list -- {status}")
        if unmatched:
            print(f"              YourTV channels Shepherd cannot match: {', '.join(unmatched)}")
            drift += 1
        if stale:
            print(f"              in channel_list but not on YourTV: {', '.join(stale)}")
        if args.fix and (unmatched or stale):
            try:
                new = rewrite_region(region, live, channels, remaps)
            except LookupError as exc:
                print(f"              could not rewrite: {exc}")
                continue
            print(f"              rewrote region {region} with {len(new)} channels")
            drift -= 1 if unmatched else 0

    if drift:
        print(f"\n{drift} region(s) have channels Shepherd would silently drop.")
        return 1
    print("\nno drift")
    return 0


if __name__ == "__main__":
    sys.exit(main())
