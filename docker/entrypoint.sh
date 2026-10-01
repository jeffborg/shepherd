#!/bin/sh
# Stage the baked distribution into the data volume, then run Shepherd.
#
# Upstream's updater installs each component as $HOME/<type>s/<name>/<name>,
# while the repo keeps them flat as <type>s/<name>. Staging does that
# transformation so the container works offline, with no first-run download.
set -eu

DIST=${SHEPHERD_DIST:-/opt/shepherd-dist}
HOME_DIR=${SHEPHERD_HOME:-/opt/shepherd}
OUT=${SHEPHERD_OUTPUT:-/output}
STAMP="$HOME_DIR/.staged-version"

log() { echo "entrypoint: $*"; }

stage() {
  # Flat -> nested, for every component listed in `status`. Keeping `status` as
  # the source of truth means we stage exactly what a release ships, so the
  # container and a self-updating install agree on what is installed.
  awk 'NF && $1 !~ /^#/ && $1 != "END" { print $1, $2 }' "$DIST/status" |
  while read -r type name; do
    case "$name" in
      *.pm)
        # Perl modules stay flat under <type>s/, mirroring query_ldir().
        install -D -m 0644 "$DIST/${type}s/$name" "$HOME_DIR/${type}s/$name"
        ;;
      *)
        install -D -m 0755 "$DIST/${type}s/$name" "$HOME_DIR/${type}s/$name/$name"
        if [ -f "$DIST/${type}s/$name.conf" ]; then
          install -D -m 0644 "$DIST/${type}s/$name.conf" \
            "$HOME_DIR/${type}s/$name/$name.conf"
        fi
        ;;
    esac
  done

  # The application is invoked through these two names.
  ln -sf applications/shepherd/shepherd "$HOME_DIR/shepherd"
  ln -sf applications/shepherd/shepherd "$HOME_DIR/tv_grab_au"
  cp -f "$DIST/status" "$DIST/status.csum" "$HOME_DIR/" 2>/dev/null || true
  dist_digest > "$STAMP"
}

# Digest the whole distribution, not just `status`: a new image that changes a
# grabber without touching `status` must still restage, or the volume silently
# keeps running the old component.
dist_digest() {
  find "$DIST" -type f -not -path '*/.git/*' -exec sha1sum {} + |
    sort -k2 | sha1sum | cut -d' ' -f1
}

# Restage whenever the image changes, so an image upgrade actually takes effect.
want=$(dist_digest)
have=$(cat "$STAMP" 2>/dev/null || echo none)
if [ "$want" != "$have" ]; then
  log "staging distribution into $HOME_DIR"
  stage
else
  log "distribution already staged"
fi

mkdir -p "$OUT"

# Derive shepherd.conf / channels.conf if they are absent, so a scheduled
# container needs no interactive `--configure`. Existing files are untouched.
perl "$DIST/docker/bootstrap-config.pl"

# Shepherd sets this itself when it invokes a component, but a component run
# directly (the `grabber` command below) needs it too.
PERL5LIB="$HOME_DIR/references${PERL5LIB:+:$PERL5LIB}"
export PERL5LIB

# Immutable by default: a container should be upgraded by pulling a new image,
# not by mutating itself. SHEPHERD_UPDATE=1 opts back into self-update.
UPDATE_FLAG=--noupdate
[ "${SHEPHERD_UPDATE:-0}" = "1" ] && UPDATE_FLAG=""

# Upstream posts anonymous usage statistics to a third-party host by default.
# That is a reasonable default for someone who installed it themselves and a
# poor one for an unattended container, so it is opt-in here.
STATS_FLAG=--nonotify
[ "${SHEPHERD_STATS:-0}" = "1" ] && STATS_FLAG=""

cmd=${1:-run}
[ $# -gt 0 ] && shift

case "$cmd" in
  run)
    exec "$HOME_DIR/shepherd" $UPDATE_FLAG $STATS_FLAG \
      --output "$OUT/${SHEPHERD_OUTPUT_FILE:-guide.xml}" "$@"
    ;;
  configure)
    # Interactive: docker run -it ... configure
    exec "$HOME_DIR/shepherd" $UPDATE_FLAG --configure "$@"
    ;;
  shepherd|tv_grab_au)
    exec "$HOME_DIR/$cmd" "$@"
    ;;
  grabber)
    # Run one grabber directly -- useful for debugging a single source.
    g=$1; shift
    exec "$HOME_DIR/grabbers/$g/$g" "$@"
    ;;
  *)
    exec "$cmd" "$@"
    ;;
esac
