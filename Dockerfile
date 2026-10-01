# Shepherd in a container.
#
# Upstream expects to be installed into a writable home directory that it then
# self-updates. That fights an immutable image, so the build bakes a read-only
# distribution into /opt/shepherd-dist and the entrypoint stages it into the
# data volume on first run. Self-update is off by default; set SHEPHERD_UPDATE=1
# to let it pull component updates at runtime.
FROM debian:13-slim

# Everything Shepherd and its live components need, from distro packages --
# upstream's install_deps builds these from CPAN at runtime, which we skip
# entirely. Note it lists JavaScript (SpiderMonkey); that is only reachable
# from the retired ninemsn grabber and is deliberately not installed.
RUN apt-get update && apt-get install -y --no-install-recommends \
      perl ca-certificates tzdata \
      libxmltv-perl libxml-writer-perl libxml-simple-perl libxml-dom-perl \
      libdate-manip-perl libdatetime-format-builder-perl \
      libdatetime-format-strptime-perl \
      libwww-perl liblwp-protocol-https-perl \
      libhtml-tree-perl libhtml-parser-perl \
      libjson-perl libsort-versions-perl libdbi-perl \
      libalgorithm-diff-perl liblist-compare-perl libcompress-raw-zlib-perl \
      libterm-readkey-perl libdbd-mysql-perl \
 && rm -rf /var/lib/apt/lists/*

# Shepherd warns and sleeps 10s twice when run as root, and its data directory
# should not be root-owned anyway.
ARG UID=1000
ARG GID=1000
RUN groupadd -g "$GID" shepherd && \
    useradd -u "$UID" -g "$GID" -d /opt/shepherd -M -s /usr/sbin/nologin shepherd

COPY . /opt/shepherd-dist
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
ENV SHEPHERD_REGION=""
RUN chmod +x /usr/local/bin/entrypoint.sh /opt/shepherd-dist/applications/shepherd && \
    mkdir -p /opt/shepherd /output && chown shepherd:shepherd /opt/shepherd /output

# Shepherd derives its own working directory: $HOME/.shepherd when HOME is set,
# otherwise /opt/shepherd. HOME=/ takes the second branch, which gives a
# predictable path with no hidden directory inside the volume.
ENV HOME=/ \
    SHEPHERD_HOME=/opt/shepherd \
    SHEPHERD_OUTPUT=/output \
    TZ=Australia/Sydney
VOLUME ["/opt/shepherd", "/output"]
USER shepherd
WORKDIR /opt/shepherd
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["run"]
