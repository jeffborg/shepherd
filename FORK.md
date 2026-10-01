# About this fork

[Upstream Shepherd](https://github.com/ShephedProject/shepherd) still works, but
it has been dormant since September 2024 and its channel maps have drifted away
from what the broadcasters actually call themselves. When a channel is renamed,
Shepherd's response is to silently stop returning it — which is how upstream
accumulated unanswered reports like *"10 peach and 10 bold no longer
populating"* and *"Name changes for Network 7 and 10"*.

This fork keeps the engine and fixes the data, adds a container, and automates
the thing that rotted.

## What changed

**Channel maps corrected for every region.** All 43 regions in
`references/channel_list` had drifted; 42 of them were dropping between four and
seven channels each. Each region was rebuilt from YourTV's live lineup.
Duplicate region lines (74, 86, 88, 102, 106, 108, 114, 256) were consolidated —
`read_official_channels()` returns on the first match, so the later copies were
unreachable.

**`util/check_channel_map.py`** reimplements Shepherd's own matching rules
(`Shepherd::Common::translate_channel_name` plus the per-region lists) and
compares them against YourTV's live lineups. CI runs it nightly and opens an
issue the day a rename appears, instead of waiting for a user to notice months
later. `--fix` rewrites the affected region lines.

**New `xmltvnet` grabber.** Rex scrapes a detail page per programme: excellent
metadata, but hours for a full region. `xmltvnet` fetches a prebuilt regional
XMLTV file from [xmltv.net](https://www.xmltv.net/) in seconds.

It is declared `category 2` (fast) with `quality 2`, which puts it behind Rex
(`quality 3`) in Shepherd's grabber scoring. That is deliberate: Rex has the
better data — 80% of programmes carry an episode name against xmltv.net's 36%,
and 43% carry credits against none — so Rex should win the standard stage and
`xmltvnet` should be the safety net. Shepherd caps each grabber with
`max_runtime` and hands whatever is left to the next best option, so if Rex
stalls, times out, or the site changes under it, the region is still covered
seconds later instead of not at all. `xmltvnet` is also the only one of the two
eligible for the "expanded" stage, which seeks episode names and accepts only
`category 2` grabbers. `reconciler_mk2` then merges whatever ran, field by
field.

Both sources ultimately derive from YourTV, so they agree on programming and
differ mainly in depth. The grabber maps channels by YourTV channel id rather
than display name — xmltv.net ids are literally `<yourtv-id>auepg.com.au`, while
its display names ("NBN NSW") do not match Shepherd's ("NBN").

**Container image**, multi-arch (amd64 + arm64), published to GHCR. Upstream
ships no image; the one third-party attempt on Docker Hub was last pushed over
seven years ago. All Perl dependencies come from distro packages — `install_deps`
and its CPAN build are skipped entirely, and the notorious `JavaScript`
(SpiderMonkey) dependency it lists is not needed, being reachable only from the
retired `ninemsn` grabber.

**Releases.** Tagging builds the image and regenerates the `release` branch that
Shepherd's own updater reads.

## Using the container

```sh
docker run --rm \
  -e SHEPHERD_REGION=184 \
  -v shepherd-data:/opt/shepherd \
  -v ./out:/output \
  ghcr.io/jeffborg/shepherd:latest run --days 7
```

The guide lands at `/output/guide.xml`. On first start the container stages its
components into the data volume and derives `shepherd.conf` and `channels.conf`
— subscribing to every channel the region carries — so no interactive
`--configure` is needed. Existing config files are never overwritten.

| variable | default | purpose |
| --- | --- | --- |
| `SHEPHERD_REGION` | *(unset)* | Shepherd region id; required on first run |
| `SHEPHERD_OUTPUT_FILE` | `guide.xml` | output filename under `/output` |
| `SHEPHERD_UPDATE` | `0` | `1` lets Shepherd self-update at runtime |
| `SHEPHERD_SOURCE` | this fork's `release` branch | component source |
| `TZ` | `Australia/Sydney` | |

Volumes are `/opt/shepherd` (state, config, caches — this is where Shepherd
expects to live when not run as a user) and `/output`.

Commands: `run` (default), `configure` (interactive, needs `-it`), `shepherd`
and `tv_grab_au` for arbitrary flags, and `grabber <name>` to run one grabber
directly.

Self-update is off by default: a container should be upgraded by pulling a new
image, not by mutating itself. The image restages whenever its contents change,
so pulling a new image takes effect on next start.

## Using it without the container

Shepherd resolves components from its `sources` list, first match wins. Adding
this fork ahead of upstream means its components take precedence and everything
it does not ship still comes from upstream — no need to switch wholesale:

```sh
shepherd --addsource https://raw.githubusercontent.com/jeffborg/shepherd/release/
```

## Scope

This fork does not try to revive Shepherd's unmaintained grabbers. `sbsweb` is
still disabled upstream, and `oztivo`, `foxtel_swf` and `abc_website` are carried
unchanged. For free-to-air Australia the working set is `rex` + `xmltvnet`.

## Icons

Upstream's icon path is dead twice over, so this takes a different route.

`add_channel_icons` looks logos up by exact channel name in `logo_list.txt`,
which still carries pre-rename names (`ABC3`, `SBS TWO`, `Prime`, `TVS`) — and
fixing the names would not help much, because the URLs behind them have rotted
too: imageshack entries 404, `imagestore.ugbox.net` no longer resolves, and 116
of the entries point at Foxtel, which is irrelevant for free-to-air.

`reconciler_mk2` separately dropped every `<icon>`, because `icon` was not in
any of its merge lists — so even a grabber that supplied logos appeared not to.

Instead, `xmltvnet` emits channel icons from YourTV's own logo URLs. It already
calls that API for the channel-id map, so the logos come free in the same
response, they are current, and they are keyed by id rather than by a name that
can be renamed out from under them. `reconciler_mk2` now carries `icon` through
for both channels and programmes (versions 0.59 and 1.01).

`add_channel_icons` is left in place and unchanged; it simply has nothing to add
when the grabber has already supplied icons.

## Known limitations

**`oztivo` and `the_movie_db_augment` fail their readiness test** in the
container and are skipped. Neither is needed for free-to-air; `oztivo`'s
`tvguide.oztivo.net` no longer resolves at all.

**xmltv.net asks for one fetch a day.** `xmltvnet` caches the downloaded file
alongside its cache file and reuses it for 12 hours (`XMLTVNET_CACHE_HOURS`),
since Shepherd may call a grabber several times in one run while filling gaps.
It also identifies itself honestly rather than impersonating a browser.
