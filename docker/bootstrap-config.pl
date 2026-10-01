#!/usr/bin/perl
#
# Generate shepherd.conf and channels.conf for a fresh container.
#
# Upstream configures interactively (`shepherd --configure`), which a scheduled
# container cannot do. Everything it asks for is derivable: the region comes
# from the environment, the channel list from references/channel_list, and the
# installed-component table from `status` plus each component's .conf.
#
# Only writes files that do not already exist, so a user who has configured
# interactively, or edited the generated files, keeps their changes.

use strict;
use warnings;
use Data::Dumper;

my $home   = $ENV{SHEPHERD_HOME}   || '/opt/shepherd';
my $region = $ENV{SHEPHERD_REGION} || 0;
my $source = $ENV{SHEPHERD_SOURCE} ||
    'https://raw.githubusercontent.com/jeffborg/shepherd/release/';

$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Indent   = 1;

sub slurp_config
{
    my $file = shift;
    return undef unless (-r $file);
    my $config;
    local (@ARGV, $/) = ($file);
    no warnings 'all';
    eval <>;
    warn "$file: $@" if ($@);
    return $config;
}

# --- components -----------------------------------------------------------
# Shepherd keys installed components by name and needs type, version, the
# parsed .conf, and a 'ready' flag so it does not re-test them on every run.
my $components = {};
open(my $st, '<', "$home/status") or die "Cannot read $home/status: $!\n";
while (my $line = <$st>) {
    chomp $line;
    next if ($line =~ /^\s*(#|$)/ || $line =~ /^END\b/);
    my ($type, $name, $version) = $line =~ /^(\S+)\s+(\S+)\s+(\S+)/ or next;
    $components->{$name} = {
        type   => $type,
        ver    => $version,
        ready  => 1,
        source => $source,
        config => ($name =~ /\.pm$/ ? undef : slurp_config("$home/${type}s/$name/$name.conf")),
    };
}
close $st;

# --- channels -------------------------------------------------------------
# Subscribe to everything the region officially carries. xmltv_ids are
# generated from the channel name so the output is usable without MythTV;
# point a PVR at these or re-run `shepherd --configure` to change them.
sub region_channels
{
    my $reg = shift or return ();
    my $fn = "$home/references/channel_list/channel_list";
    open(my $fh, '<', $fn) or do { warn "Cannot read $fn: $!\n"; return () };
    while (my $line = <$fh>) {
        chomp $line;
        return split(/,/, $1) if ($line =~ /^$reg:(.*)/);
    }
    warn "Region $reg not found in $fn\n";
    return ();
}

sub xmltv_id
{
    my ($name, $reg) = @_;
    (my $slug = lc $name) =~ s/[^a-z0-9]+/-/g;
    $slug =~ s/^-|-$//g;
    return "$slug.$reg.shepherd.au";
}

my $chanfile = "$home/channels.conf";
if (-e $chanfile) {
    print "bootstrap: $chanfile exists, leaving it alone\n";
} elsif (!$region) {
    print "bootstrap: SHEPHERD_REGION not set; skipping channels.conf\n";
} else {
    my @names = region_channels($region);
    die "bootstrap: no channels known for region $region\n" unless (@names);
    my $channels = { map { $_ => xmltv_id($_, $region) } @names };
    my $opt_channels = {};
    open(my $out, '>', $chanfile) or die "Cannot write $chanfile: $!\n";
    print $out Data::Dumper->Dump([$channels, $opt_channels], ['channels', 'opt_channels']);
    close $out;
    printf "bootstrap: wrote %s with %d channels for region %s\n",
           $chanfile, scalar(@names), $region;
}

# --- shepherd.conf --------------------------------------------------------
my $conffile = "$home/shepherd.conf";
if (-e $conffile) {
    print "bootstrap: $conffile exists, leaving it alone\n";
    exit 0;
}
# Not fatal: the image must still answer --version/--capabilities and run a
# single grabber without a region. Shepherd raises its own error if it is
# actually asked to grab without configuration.
unless ($region) {
    print "bootstrap: SHEPHERD_REGION not set; skipping shepherd.conf\n";
    exit 0;
}

my $pref_title_source        = undef;
my $want_paytv_channels      = 0;
my $sysid                    = $ENV{SHEPHERD_SYSID} || 'container';
my $last_successful_run      = 0;
my $last_successful_run_data = undef;
my $last_successful_runs     = {};
my $last_successful_refresh  = 0;
my $sources                  = [ $source ];
my $components_pending_install = {};
my $pending_messages         = {};   # hash, not array: build_stats() does keys %$pending_messages

open(my $out, '>', $conffile) or die "Cannot write $conffile: $!\n";
print $out Data::Dumper->Dump(
    [ $region, $pref_title_source, $want_paytv_channels, $sysid,
      $last_successful_run, $last_successful_run_data, $last_successful_runs,
      $last_successful_refresh, $sources, $components,
      $components_pending_install, $pending_messages ],
    [ "region", "pref_title_source", "want_paytv_channels", "sysid",
      "last_successful_run", "last_successful_run_data", "last_successful_runs",
      'last_successful_refresh', 'sources', "components",
      "components_pending_install", "pending_messages" ]);
close $out;
printf "bootstrap: wrote %s (region %s, %d components)\n",
       $conffile, $region, scalar(keys %$components);
