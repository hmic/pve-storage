package PVE::Storage::ISCSIPlugin;

use strict;
use warnings;

use File::stat;
use IO::Dir;
use IO::File;

use PVE::JSONSchema qw(get_standard_option);
use PVE::Storage::Plugin;
use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach $IPV4RE $IPV6RE);

use base qw(PVE::Storage::Plugin);

# iscsi helper function

my $ISCSIADM = '/usr/bin/iscsiadm';

my $found_iscsi_adm_exe;
my sub assert_iscsi_support {
    my ($noerr) = @_;
    return $found_iscsi_adm_exe if $found_iscsi_adm_exe; # assume it won't be removed if ever found

    $found_iscsi_adm_exe = -x $ISCSIADM;

    if (!$found_iscsi_adm_exe) {
	die "error: no iscsi support - please install open-iscsi\n" if !$noerr;
	warn "warning: no iscsi support - please install open-iscsi\n";
    }
    return $found_iscsi_adm_exe;
}

# Example: 192.168.122.252:3260,1 iqn.2003-01.org.linux-iscsi.proxmox-nfs.x8664:sn.00567885ba8f
my $ISCSI_TARGET_RE = qr/^((?:$IPV4RE|\[$IPV6RE\]):\d+)\,\S+\s+(\S+)\s*$/;

sub iscsi_session_list {
    assert_iscsi_support();

    my $cmd = [$ISCSIADM, '--mode', 'session'];

    my $res = {};
    eval {
	run_command($cmd, errmsg => 'iscsi session scan failed', outfunc => sub {
	    my $line = shift;
	    # example: tcp: [1] 192.168.122.252:3260,1 iqn.2003-01.org.linux-iscsi.proxmox-nfs.x8664:sn.00567885ba8f (non-flash)
	    if ($line =~ m/^tcp:\s+\[(\S+)\]\s+((?:$IPV4RE|\[$IPV6RE\]):\d+)\,\S+\s+(\S+)\s+\S+?\s*$/) {
		my ($session_id, $portal, $target) = ($1, $2, $3);
		# there can be several sessions per target (multipath)
		push @{$res->{$target}}, { session_id => $session_id, portal => $portal };
	    }
	});
    };
    if (my $err = $@) {
	die $err if $err !~ m/: No active sessions.$/i;
    }

    return $res;
}

sub iscsi_test_portal {
    my ($portal) = @_;

    my ($server, $port) = PVE::Tools::parse_host_and_port($portal);
    return 0 if !$server;
    return PVE::Network::tcp_ping($server, $port || 3260, 2);
}

sub iscsi_portals {
    my ($target, $portal_in) = @_;

    assert_iscsi_support();

    my $res = [];
    my $cmd = [$ISCSIADM, '--mode', 'node'];
    eval {
	run_command($cmd, outfunc => sub {
	    my $line = shift;

	    if ($line =~ $ISCSI_TARGET_RE) {
		my ($portal, $portal_target) = ($1, $2);
		if ($portal_target eq $target) {
		    push @{$res}, $portal;
		}
	    }
	});
    };

    if ($@) {
	warn $@;
	return [ $portal_in ];
    }

    return $res;
}

sub iscsi_discovery {
    my ($portals) = @_;

    assert_iscsi_support();

    my $res = {};
    for my $portal ($portals->@*) {
	next if !iscsi_test_portal($portal); # fixme: raise exception here?

	my $cmd = [$ISCSIADM, '--mode', 'discovery', '--type', 'sendtargets', '--portal', $portal];
	eval {
	    run_command($cmd, outfunc => sub {
		my $line = shift;

		if ($line =~ $ISCSI_TARGET_RE) {
		    my ($portal, $target) = ($1, $2);
		    # one target can have more than one portal (multipath)
		    # and sendtargets should return all of them in single call
		    push @{$res->{$target}}, $portal;
		}
	    });
	};

	# In case of multipath we can stop after receiving targets from any available portal
	last if scalar(keys %$res) > 0;
    }

    return $res;
}

sub iscsi_login {
    my ($target, $portals) = @_;

    assert_iscsi_support();

    eval { iscsi_discovery($portals); };
    warn $@ if $@;

    # Disable retries to avoid blocking pvestatd for too long, next iteration will retry anyway
    eval {
	my $cmd = [
	    $ISCSIADM,
	    '--mode', 'node',
	    '--targetname', $target,
	    '--op', 'update',
	    '--name', 'node.session.initial_login_retry_max',
	    '--value', '0',
	];
	run_command($cmd);
    };
    warn $@ if $@;

    run_command([$ISCSIADM, '--mode', 'node', '--targetname',  $target, '--login']);
}

sub iscsi_logout {
    my ($target) = @_;

    assert_iscsi_support();

    run_command([$ISCSIADM, '--mode', 'node', '--targetname', $target, '--logout']);
}

my $rescan_filename = "/var/run/pve-iscsi-rescan.lock";

sub iscsi_session_rescan {
    my $session_list = shift;

    assert_iscsi_support();

    my $rstat = stat($rescan_filename);

    if (!$rstat) {
	if (my $fh = IO::File->new($rescan_filename, "a")) {
	    utime undef, undef, $fh;
	    close($fh);
	}
    } else {
	my $atime = $rstat->atime;
	my $tdiff = time() - $atime;
	# avoid frequent rescans
	return if !($tdiff < 0 || $tdiff > 10);
	utime undef, undef, $rescan_filename;
    }

    foreach my $session (@$session_list) {
	my $cmd = [$ISCSIADM, '--mode', 'session', '--sid', $session->{session_id}, '--rescan'];
	eval { run_command($cmd, outfunc => sub {}); };
	warn $@ if $@;
    }
}

sub load_stable_scsi_paths {

    my $stable_paths = {};

    my $stabledir = "/dev/disk/by-id";

    if (my $dh = IO::Dir->new($stabledir)) {
	foreach my $tmp (sort $dh->read) {
           # exclude filenames with part in name (same disk but partitions)
           # use only filenames with scsi(with multipath i have the same device
	   # with dm-uuid-mpath , dm-name and scsi in name)
           if($tmp !~ m/-part\d+$/ && ($tmp =~ m/^scsi-/ || $tmp =~ m/^dm-uuid-mpath-/)) {
                 my $path = "$stabledir/$tmp";
                 my $bdevdest = readlink($path);
		 if ($bdevdest && $bdevdest =~ m|^../../([^/]+)|) {
		     $stable_paths->{$1}=$tmp;
		 }
	   }
       }
       $dh->close;
    }
    return $stable_paths;
}

sub iscsi_device_list {

    my $res = {};

    my $dirname = '/sys/class/iscsi_session';

    my $stable_paths = load_stable_scsi_paths();

    dir_glob_foreach($dirname, 'session(\d+)', sub {
	my ($ent, $session) = @_;

	my $target = file_read_firstline("$dirname/$ent/targetname");
	return if !$target;

	my (undef, $host) = dir_glob_regex("$dirname/$ent/device", 'target(\d+):.*');
	return if !defined($host);

	dir_glob_foreach("/sys/bus/scsi/devices", "$host:" . '(\d+):(\d+):(\d+)', sub {
	    my ($tmp, $channel, $id, $lun) = @_;

	    my $type = file_read_firstline("/sys/bus/scsi/devices/$tmp/type");
	    return if !defined($type) || $type ne '0'; # list disks only

	    my $bdev;
	    if (-d "/sys/bus/scsi/devices/$tmp/block") { # newer kernels
		(undef, $bdev) = dir_glob_regex("/sys/bus/scsi/devices/$tmp/block/", '([A-Za-z]\S*)');
	    } else {
		(undef, $bdev) = dir_glob_regex("/sys/bus/scsi/devices/$tmp", 'block:(\S+)');
	    }
	    return if !$bdev;

	    #check multipath
	    if (-d "/sys/block/$bdev/holders") {
		my $multipathdev = dir_glob_regex("/sys/block/$bdev/holders", '[A-Za-z]\S*');
		$bdev = $multipathdev if $multipathdev;
	    }

	    my $blockdev = $stable_paths->{$bdev};
	    return if !$blockdev;

	    my $size = file_read_firstline("/sys/block/$bdev/size");
	    return if !$size;

	    my $volid = "$channel.$id.$lun.$blockdev";

	    $res->{$target}->{$volid} = {
		'format' => 'raw',
		'size' => int($size * 512),
		'vmid' => 0, # not assigned to any vm
		'channel' => int($channel),
		'id' => int($id),
		'lun' => int($lun),
	    };

	    #print "TEST: $target $session $host,$bus,$tg,$lun $blockdev\n";
	});

    });

    return $res;
}

# Configuration

sub type {
    return 'iscsi';
}

sub plugindata {
    return {
	content => [ {images => 1, none => 1}, { images => 1 }],
	select_existing => 1,
    };
}

sub properties {
    return {
	target => {
	    description => "iSCSI target.",
	    type => 'string',
	},
	portal => {
	    description => "iSCSI portal (IP or DNS name with optional port).",
	    type => 'string', format => 'pve-storage-portal-dns',
	},
    };
}

sub options {
    return {
        portal => { fixed => 1 },
        target => { fixed => 1 },
        nodes => { optional => 1},
	disable => { optional => 1},
	content => { optional => 1},
	bwlimit => { optional => 1 },
    };
}

# Storage implementation

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m!^\d+\.\d+\.\d+\.(\S+)$!) {
	return ('images', $1, undef, undef, undef, undef, 'raw');
    }

    die "unable to parse iscsi volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "snapshot is not possible on iscsi storage\n" if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $path = "/dev/disk/by-id/$name";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "can't create base images in iscsi storage\n";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "can't clone images in iscsi storage\n";
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "can't allocate space in iscsi storage\n";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    die "can't free space in iscsi storage\n";
}

# list all luns regardless of set content_types, since we need it for
# listing in the gui and we can only have images anyway
sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;

    my $res = $class->list_images($storeid, $scfg, $vmid);

    for my $item (@$res) {
	$item->{content} = 'images'; # we only have images
    }

    return $res;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = [];

    $cache->{iscsi_devices} = iscsi_device_list() if !$cache->{iscsi_devices};

    # we have no owner for iscsi devices

    my $target = $scfg->{target};

    if (my $dat = $cache->{iscsi_devices}->{$target}) {

	foreach my $volname (keys %$dat) {

	    my $volid = "$storeid:$volname";

	    if ($vollist) {
		my $found = grep { $_ eq $volid } @$vollist;
		next if !$found;
	    } else {
		# we have no owner for iscsi devices
		next if defined($vmid);
	    }

	    my $info = $dat->{$volname};
	    $info->{volid} = $volid;

	    push @$res, $info;
	}
    }

    return $res;
}

sub iscsi_session {
    my ($cache, $target) = @_;
    $cache->{iscsi_sessions} = iscsi_session_list() if !$cache->{iscsi_sessions};
    return $cache->{iscsi_sessions}->{$target};
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $session = iscsi_session($cache, $scfg->{target});
    my $active = defined($session) ? 1 : 0;

    return (0, 0, 0, $active);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return if !assert_iscsi_support(1);

    my $sessions = iscsi_session($cache, $scfg->{target});
    my $portals = iscsi_portals($scfg->{target}, $scfg->{portal});
    my $do_login = !defined($sessions);

    if (!$do_login) {
	# We should check that sessions for all portals are available
	my $session_portals = [ map { $_->{portal} } (@$sessions) ];

	for my $portal (@$portals) {
	    if (!grep(/^\Q$portal\E$/, @$session_portals)) {
		$do_login = 1;
		last;
	    }
	}
    }

    if ($do_login) {
	eval { iscsi_login($scfg->{target}, $portals); };
	warn $@ if $@;
    } else {
	# make sure we get all devices
	iscsi_session_rescan($sessions);
    }
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return if !assert_iscsi_support(1);

    if (defined(iscsi_session($cache, $scfg->{target}))) {
	iscsi_logout($scfg->{target});
    }
}

sub check_connection {
    my ($class, $storeid, $scfg) = @_;

    my $portals = iscsi_portals($scfg->{target}, $scfg->{portal});

    for my $portal (@$portals) {
	my $result = iscsi_test_portal($portal);
	return $result if $result;
    }

    return 0;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
    die "volume resize is not possible on iscsi device";
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
	copy => { current => 1},
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;
    if ($snapname){
	$key = 'snap';
    } else {
	$key = $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}


1;
