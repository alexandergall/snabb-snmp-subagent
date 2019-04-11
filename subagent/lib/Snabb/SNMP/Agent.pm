###
### Copyright (C) 2016 Alexander Gall <gall@switch.ch>
###
### This program is free software: you can redistribute it and/or
### modify it under the terms of the GNU General Public License as
### published by the Free Software Foundation, either version 3 of the
### License, or (at your option) any later version.
###
### This program is distributed in the hope that it will be useful,
### but WITHOUT ANY WARRANTY; without even the implied warranty of
### MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
### General Public License for more details.
###
### You should have received a copy of the GNU General Public License
### along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Snabb::SNMP::Agent;

=head1 NAME

Snabb::SNMP::Agent

=head1 SYNOPSIS

use Snabb::SNMP::Agent;

=head1 DESCRITPION

Clients of this module must pass a reference to a hash (referred
to as %subtrees in the following) that defines the subtrees that
it wants to have registered with the master agent.  The hash must
be structured as follows.

The term "object" refers to a string which is either a literal OID
(in dotted notation) or a name that can be translated to an OID
through the loaded MIBs (via %SNMP::MIB).

The keys of %subtrees are objects that designate the subtrees that
will be registered with the master agent.  Each subtree may
contain two hashes named "handlers" and "tables".  The keys of
these hashes are objects which must be part of the subtree.
Subtrees must not overlap.

The "tables" hash must contain a key called "indexer", which must
be a reference to a function that is able to create the full
instance ID (IID) for any object in the table.

The subtrees are populated with objects from memory segments
shared with Snabb instances that use the lib.ipc.shmem mechansim
with the name space "MIB" as follows.

Once an object is read from the index file of a shared memory
segment, a lookup in the subtree hash is performed to find the
subtree that contains it.  If no match is found, the object is
ignored.  Otherwise, the object is matched against all tables
which are registered in the "tables" hash of the subtree.  If the
object is not covered by any table, it is considered to be a
scalar object and the IID is constructed from the object's OID by
adding the index ".0".  Otherwise, the object is considered to be
part of the table and its indexer function is called with the OID
of the object, the base OID of the table and a reference to a hash
that describes the segment.  The indexer returns the IID of the
object.

The value that will be returned for a query for the IID is
generated as follows.  The data type of the object is obtained
from the MIB by referencing the "type" field of the OID node
returned from a lookup in %SNMP::MIB.  The type is associated with
a class of the Snabb::SNMP::Tie package via the hash %class_map.
A scalar variable is then tied to this class, passing a reference
to the segment descriptor and the name of the object and possibly
a "handler".  The purpose of the handler is to apply
object-specfic manipulations to the value obtained from the shared
segment before passing it on to the master agent.

The handler of an object is determined as follows.  If the object
is a scalar, it is looked up in the "handlers" hash of its
subtree.  If it is part of a table, the lookup is done in the
"handlers" hash of the table instead.  If the lookup fails, the
tied scalar uses no handler.  If the lookup succeeds, the
corresponding value is interpreted as a reference to a function
and associated with the tied variable.

Finally, the IID is registered in the master MIB table %mibs as a
hash that contains the keys "type" and "value", where the type is
the data type of the object (more precisely, the type translated
through the hash %type_tr) and the value is a reference to the
tied value.

When a request for the IID is received, the tied variable is
dereferenced to obtain the object's value.  Essentially, the Tie
class will read the raw value from the shared memory segment and
transform it to the proper type.  If the object is associated with
a handler, the handler is called with the value and a reference to
the segment descriptor to apply any special processing.  Finally,
the resulting value will be stored in the sub-agent's PDU and
handed back to the master agent.

head1 METHODS

Snabb::SNMP::Agent::start({ name => "agent-name",
                            subtrees => \%subtrees,
			    check_interval => 5,
			    if_index => "./ifindex",
                            mibs_dirs => '',
                            mibs => '',
                            shmem_dir => "/var/run/shmem",
			  });

=cut

use 5.020002;
use strict;
use warnings;
use SNMP;
use NetSNMP::agent qw (:all);
use NetSNMP::ASN qw(:all);
use Net::SNMP;
use Sys::Mmap;
use Snabb::SNMP::Tie;
use IO::Handle;
use Exporter ();
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(scalar_indexer %compound_scalar_handlers %persistent_ifIndex $sysUpTime $sysUpTime_base);
our $VERSION = '0.01';


## Default configuration
my %config = ( check_interval => undef,
	       subtrees => undef,
	       if_index => '',
               name => undef,
               shmem_dir => undef,
               mibs_dirs => undef,
               mibs => undef,
	     );

## TODO: remove use vars qw($sysUpTime_base);
## Value of sysUpTime at startup
our ($sysUpTime, $sysUpTime_base);
our %persistent_ifIndex;

### Mappings of types provided by SNMP::getType() to
### the subclass of Snabb::SNMP::Tie that handles it.
my %class_map = ( INTEGER => 'Snabb::SNMP::Tie::INTEGER',
		  UNSIGNED32 => 'Snabb::SNMP::Tie::INTEGER',
		  INTEGER32 => 'Snabb::SNMP::Tie::INTEGER',
		  COUNTER => 'Snabb::SNMP::Tie::INTEGER',
		  COUNTER64 => 'Snabb::SNMP::Tie::INTEGER64',
		  TICKS => 'Snabb::SNMP::Tie::TICKS',
		  OCTETSTR => 'Snabb::SNMP::Tie::OCTETSTR',
		  BITS => 'Snabb::SNMP::Tie::OCTETSTR',
		  GAUGE => 'Snabb::SNMP::Tie::INTEGER',
		);


my $rebuild_mib = 0;

### Mappings of types provided by SNMP::getType() to those
### used by NetSNMP::ASN
my %type_tr =
  ( OCTETSTR => ASN_OCTET_STR,
    INTEGER => ASN_INTEGER,
    INTEGER32 => ASN_INTEGER,
    UNSIGNED32 => ASN_UNSIGNED,
    COUNTER => ASN_COUNTER,
    COUNTER64 => ASN_COUNTER64,
    TICKS => ASN_TIMETICKS,
    BITS => ASN_OCTET_STR,
    GAUGE => ASN_GAUGE,
  );

##
my $snabb_shmem_dir_ctime = 0;
my %shmem;
our %compound_scalar_handlers =
  ( accumulator => sub {
      my ($values_ref) = @_;
      my $accum = 0;
      foreach (@{$values_ref}) {
	$accum = $accum + ${$_};
      }
      return int($accum);
    },
  );

## Indexer for scalar objects. Simply attaches ".0" to the OID.
sub scalar_indexer($$$) {
  my ($oid) = @_;
  return($oid.".0");
}

my (%mibs_sorted, %mibs_persistent);

sub check_subtrees() {
  foreach my $st (keys(%{$config{subtrees}})) {
    my $st_oid_node = $SNMP::MIB{$st} or die
      "Unknown subtree $st";
    print("Checking subtree $st\n");
    my $st_oid = $st_oid_node->{objectID};
    foreach my $st2 (keys(%{$config{subtrees}})) {
      my $st2_oid = $config{subtrees}->{$st2}{oid};
      next if not defined $st2_oid;
      not Net::SNMP::oid_base_match($st2_oid, $st_oid) or
	die "Subtree $st_oid ($st) overlaps with $st2 ($st2_oid)";
    }
    my $subtree = $config{subtrees}->{$st};
    $subtree->{oid} = $st_oid;
    $subtree->{mib} = {};
    foreach my $table (keys(%{$subtree->{tables}})) {
      my $ref = $subtree->{tables}{$table};
      if (not exists $ref->{indexer}) {
	if ($table eq 'scalars') {
	  $ref->{indexer} = \&scalar_indexer;
	} else {
	  die "Missing indexer for table $table";
	}
      }
      my ($parent, $parent_oid) = ($st, $st_oid);
      unless ($table eq 'scalars') {
	print("\tChecking table $table\n");
	my $table_oid_node = $SNMP::MIB{$table} or
	  die "Unknown table $table";
	my $table_oid = $table_oid_node->{objectID};
	Net::SNMP::oid_base_match($st_oid, $table_oid) or
	    die "Table $table ($table_oid) is not a child "
	      ."of the subtree $st ($st_oid)";
	foreach my $table2 (keys(%{$subtree->{tables}})) {
	  my $table2_oid = $subtree->{tables}{$table}{oid};
	  next unless defined $table2_oid;
	  Net::SNMP::oid_base_match($table2_oid, $table_oid) and
	      die "Illegal nesting of tables: $table (%table_oid) "
		." is contained in $table2 ($table2_oid)";
	}
	$ref->{oid} = $table_oid;
	($parent, $parent_oid) = ($table, $table_oid);
      }
      $ref->{name} = $table;
      foreach my $obj (keys(%{$ref->{handlers}})) {
	print("\tChecking handler for object $obj\n");
	my $obj_oid_node = $SNMP::MIB{$obj} or
	  die "Unknown object $obj\n";
	my $obj_oid = $obj_oid_node->{objectID};
	Net::SNMP::oid_base_match($parent_oid, $obj_oid) or
	  die "Object $obj ($obj_oid) is not a child "
	    ." of the $parent MIB ($parent_oid)";
	my $ref2 = $ref->{handlers}{$obj};
	$ref2->{oid} = $obj_oid;
	$ref2->{name} = $obj;
	if ($table eq 'scalars' and exists $ref2->{compound_handler}) {
	  my $type = $obj_oid_node->{type};
	  my $type_tr = $type_tr{$type};
	  defined $type_tr or die "missing type translation for $type";
	  $mibs_persistent{$st_oid}{$obj_oid.".0"} =
	    { compound_handler => $ref2->{compound_handler},
	      type => $type_tr
	    };
	}
      }
    }
  }
}

sub find_object ($) {
  my ($oid) = @_;
  foreach my $st (keys(%{$config{subtrees}})) {
    if (Net::SNMP::oid_base_match($config{subtrees}->{$st}{oid}, $oid)) {
      foreach my $table (keys(%{$config{subtrees}->{$st}{tables}})) {
	next if $table eq 'scalars';
	my $ref = $config{subtrees}->{$st}{tables}{$table};
	Net::SNMP::oid_base_match($ref->{oid}, $oid) and
	    return $config{subtrees}->{$st}{mib}, $config{subtrees}->{$st}{oid}, $ref;
      }
      ## The object is covered by the subtree but not by any of its
      ## tables, i.e. it must be a scalar.
      return $config{subtrees}->{$st}{mib}, $config{subtrees}->{$st}{oid},
	$config{subtrees}->{$st}{tables}{scalars};
    }
  }
  ## Not covered by any subtree.
  return undef, undef, undef;
}

sub parse_shmem() {
  %shmem = ();
  opendir(SHMEMD, $config{shmem_dir}) or die
    "Can't open directory $config{shmem_dir}: $!";
  $snabb_shmem_dir_ctime = (stat(SHMEMD))[9] or die
    "stat of directory $config{shmem_dir} failed: $!";
  foreach my $idx (readdir(SHMEMD)) {
    next unless ($idx =~ /\.index$/);
    my $file = join('/', $config{shmem_dir}, $idx);
    unless (open(IDX, $file)) {
      warn "Can't open index file $idx: $!, skipping";
      next;
    }
    my $idx_mtime = (stat(IDX))[9];
    unless (defined $idx_mtime) {
      warn "Can't stat index file $idx: $!, skipping";
      close(IDX);
      next;
    }

    print("Reading index $idx\n");
    my $offset = 0;
    my $header = <IDX>;
    chomp $header;
    my ($namespace, $version);
    if ((($namespace, $version) = split(':', $header)) != 2) {
      warn "$idx: malformed header line: $header, skipping file";
      close(IDX);
      next;
    }
    if ($namespace ne "MIB") {
      warn "$idx: name space $namespace, skipping";
      close(IDX);
      next;
    }
    if ($version != 1) {
      warn "$idx: unsupported version (expected 1): $version, skipping";
      close(IDX);
      next;
    }
    my %objs;
    while (<IDX>) {
      chomp;
      (my ($name, $length) = split(':')) == 2 or die
	"Malformed index in $idx: $_";
      ## print("Object $name ($offset, $length)\n");
      my $oid_node = undef;
      ## Check for marker that the name is not actually a MIB object.
      $oid_node = $SNMP::MIB{$name};
      ## Weird: when an non-existant object is accessed for the
      ## first time, the result is undef, but subsequent accesses
      ## return a reference to an empty hash :/
      if (not $name =~ /^_X/ and (not defined $oid_node or
                             keys(%{$oid_node}) == 0)) {
	##warn "$idx: unokwn object $name, skipping";
      } else {
        not defined $objs{$name} or die
          "Duplicate object $name";
        $objs{$name} = { offset => $offset,
                         length => $length,
                         oid_node => $oid_node };
      }
      $offset = $offset + $length;
    }
    close(IDX) or die "Can't close index $idx: $!";

    (my $segment = $idx) =~ s/\.index$//;
    $file = join('/', $config{shmem_dir}, $segment);
    print("Processing segment $segment ($file)\n");
    my $seg_fh;
    unless (open($seg_fh, "<$file")) {
      warn "Can't open data file $file: $!, skipping";
      next;
    }
    my $size = (stat($seg_fh))[7];
    unless (defined $size) {
      warn "Can't stat file $file: $!, skipping";
      close($seg_fh);
      next;
    }
    my $mmap;
    unless (mmap($mmap, $size, PROT_READ, MAP_SHARED, $seg_fh)) {
      warn "mmap failed for file $file: $!, skipping";
      close($seg_fh);
      next;
    }
    my %segment = ( idx_mtime => $idx_mtime,
		    name => $segment,
		    file => $file,
		    fh   => $seg_fh,
		    mmap => \$mmap,
		    objs => \%objs );
    $offset == $size or die "File size mismatch, expected $offset, got $size";
    $shmem{$segment} = \%segment;
  }
  close(SHMEMD);
}

sub populate_mibs () {
  print("Populating MIBs\n");

  ### Delete all existing objects in the MIBs of all subtrees and copy
  ### the persistent entries for scalar objects.
  foreach (keys(%{$config{subtrees}})) {
    %{$config{subtrees}->{$_}{mib}} = ();
    my $mib_oid = $config{subtrees}->{$_}{oid};
    foreach my $oid (keys(%{$mibs_persistent{$mib_oid}})) {
      %{$config{subtrees}->{$_}{mib}{$oid}} = %{$mibs_persistent{$mib_oid}{$oid}};
    }
  }
 SEGMENT:
  foreach my $segment (keys(%shmem)) {
    print("Processing segment $segment\n");
    my $seg_ref = $shmem{$segment};
    foreach my $obj (keys(%{$seg_ref->{objs}})) {
      next if $obj =~ /^_X/;
      ##print("Processing object $obj\n");
      my $obj_ref = $seg_ref->{objs}{$obj};
      my $oid_node = $obj_ref->{oid_node};
      my $oid = $oid_node->{objectID};
      my ($mib, $mib_oid, $table) = find_object($oid);
      if (not defined $mib) {
        ##warn "$obj ($oid) not covered by any configured subtree";
        next;
      }
      my $iid = $table->{indexer}($oid, $table->{oid}, $seg_ref);
      $iid or next SEGMENT;
      my $handler;
      foreach my $obj2 (keys(%{$table->{handlers}})) {
	if ($oid eq $table->{handlers}{$obj2}{oid}) {
	  $handler = $table->{handlers}{$obj2}{handler};
	  last;
	}
      }
      my $type = $oid_node->{type};
      my $class = $class_map{$type};
      defined $class or die "Missing class mapping for $type";
      my $type_tr = $type_tr{$type};
      defined $type_tr or die "Missing type translation for $type";

      ## The value is tied to the object that represents it in the
      ## current segment, irrespective of whether it is a columnar
      ## object or a scalar.
      my $value;
      tie $value, $class_map{$type}, $seg_ref, $obj, $handler;

      not exists $mib->{$iid} and $mib->{$iid} = {};
      $mib->{$iid}{type} = $type_tr;
      if ($table->{name} ne 'scalars') {
	$mib->{$iid}{value} = \$value;
      } else {
	## A scalar is allowed to exist in multiple segments.  At this
	## point, we collect all instances of its tied values.
	push(@{$mib->{$iid}{values}}, \$value);
      }
    }
  }
}

sub sort_mibs() {
  foreach my $st (keys(%{$config{subtrees}})) {
    my $mib = $config{subtrees}->{$st}{mib};
    my $mib_oid = $config{subtrees}->{$st}{oid};
    @{$mibs_sorted{$mib_oid}} = ();
    my @mib_sorted = Net::SNMP::oid_lex_sort(keys(%{$mib}));
    for (my $i = 0; $i < $#mib_sorted; $i++) {
      my $oid = $mib_sorted[$i];
      $mib->{$oid}->{next} = $mib_sorted[$i+1];
    }
    if (@mib_sorted > 0) {
      $mib->{$mib_sorted[$#mib_sorted]}->{next} = undef;
    }
    $mibs_sorted{$mib_oid} = \@mib_sorted;
  }
}

sub maybe_rebuild_mibs() {
  if ($rebuild_mib) {
    print("(Re)building MIBs\n");
    for my $segment (keys(%shmem)) {
      my $file = $shmem{$segment}{file};
      print("Closing $file\n");
      munmap(${$shmem{$segment}{mmap}}) or die
	"munmap failed for $file: $!";
      close($shmem{$segment}{fh}) or die
	"Close of $file failed: $!";
    }
    parse_shmem();
    populate_mibs();
    sort_mibs();
    $rebuild_mib = 0;
  }
}

sub agentx_handler {
  my ($handler, $registration_info, $request_info, $requests) = @_;
  my $request;

  maybe_rebuild_mibs();
  for($request = $requests; $request; $request = $request->next()) {
    my $oid_o = $request->getOID();
    my $oid = '.'.join('.', $oid_o->to_array());
    my ($mib, $mib_oid) = find_object($oid) or die
      "OID $oid not within any registered subtree";
    my $obj;
    if ($request_info->getMode() == MODE_GET) {
      ## print("GET $oid\n");
      $obj = $mib->{$oid};
    } elsif ($request_info->getMode() == MODE_GETNEXT) {
      ## print("GETNEXT $oid\n");
      my $next_oid = undef;
      foreach (@{$mibs_sorted{$mib_oid}}) {
	my $cmp = Net::SNMP::oid_lex_cmp($oid, $_);
	if ( $cmp <= 0) {
	  if ($cmp < 0) {
	    $next_oid = $_;
	  } else {
	    $next_oid = $mib->{$oid}->{next};
	  }
	  if (defined $next_oid) {
	    $obj = $mib->{$next_oid};
	    $request->setOID($next_oid);
	  }
	  last;
	}
      }
    }
    if (defined $obj) {
      my $value;
      if ($obj->{value}) {
	$value = ${$obj->{value}};
      } else {
	## Compound scalar
	if ($obj->{compound_handler}) {
	  $value = $obj->{compound_handler}($obj->{values});
	} elsif (scalar(@{$obj->{values}}) == 1) {
	  $value = ${@{$obj->{values}}[0]};
	} else {
	  die "No comopund handler for multi scalar $oid";
	}
      }
      $request->setValue($obj->{type}, $value);
    } else {
      ## Nothing found.  Not sure if we need to do anything special here.
    }
  }
}

sub idx_watcher() {
  unless ($rebuild_mib) {
    if (opendir(SHMEMD, $config{shmem_dir})) {
      my $ctime = (stat(SHMEMD))[9] or die
	"stat of directory $config{shmem_dir} failed: $!";
      close(SHMEMD);
      if ($ctime != $snabb_shmem_dir_ctime) {
	print("idx_watcher: data directory $config{shmem_dir} change detected\n");
	$rebuild_mib = 1;
      } else {
	for my $segment (keys(%shmem)) {
	  my $idx = $shmem{$segment}{file}.".index";
	  open(IDX, $idx) or die
	    "idx_watcher: can't open $idx: $!";
	  my $mtime = (stat(IDX))[9] or die
	    "idx_watcher: can't stat $idx: $!";
	  close(IDX);
	  if ($mtime != $shmem{$segment}{idx_mtime}) {
	    print("idx_watcher: $idx changed\n");
	    $rebuild_mib = 1;
	    last;
	  }
	}
      }
    } else {
      warn "open of directory $config{shmem_dir} failed: $!";
    }
  }
  alarm $config{check_interval};
}

sub start($) {
  my ($args) = @_;

  for my $option (keys(%config)) {
    if (exists $args->{$option}) {
      $config{$option} = $args->{$option};
    } else {
      unless (defined $config{$option}) {
	die "missing mandatory option $option";
      }
    }
  }

  ## Parse the persistent ifIndex table
  if ($config{if_index}) {
    open(IFINDEX, $config{if_index}) or
      die "Can't open ifIndex file $config{if_index}: $!";
    while (<IFINDEX>) {
      chomp;
      (my ($if, $index) = split(/\s+/)) == 2 or
        die "Parse error in ifIndex file $config{if_index}";
      print("Adding ifIndex $index => $if\n");
      $persistent_ifIndex{$if} = $index;
    }
    close(IFINDEX);
  }

  $config{mibs_dirs} and $ENV{MIBDIRS} = "+$config{mibs_dirs}";
  $config{mibs} and $ENV{MIBS} = $config{mibs};

  STDERR->autoflush();
  STDOUT->autoflush();

  print("agent new $config{name}\n");
  my $agent =
    NetSNMP::agent->new(
                        # makes the agent read a my_agent_name.conf file
                        Name => $config{name},
                        AgentX => 1,
                       ) or die "Couldn't create agent";

  ## Determine base of sysUpTime
  my ($sess, $err) = Net::SNMP->session(Hostname => 'localhost',
					Community => 'snabb');
  $sess or die "SNMP session error: $err";
  $sess->translate(0);
  my $sysUpTimeOID = $SNMP::MIB{sysUpTime}->{objectID} or die;
  my $res = $sess->get_request($sysUpTimeOID.".0");
  if (not defined $res) {
    $sess->close();
    die "SNMP get error ".$sess->error();
  }
  $sysUpTime = int($res->{$sysUpTimeOID.".0"});
  $sess->close();
  ## SNMP timer ticks are in 1/100 seconds
  $sysUpTime_base = time()-int($sysUpTime/100);

  alarm $config{check_interval};
  check_subtrees();
  maybe_rebuild_mibs();

  $SIG{ALRM} = \&idx_watcher;
  $SIG{INT} = sub {
    $agent->shutdown();
    exit(0);
  };

  for my $st (keys(%{$config{subtrees}})) {
    my $st_oid = $config{subtrees}->{$st}{oid};
    print("Registering subtree $st ($st_oid)\n");
    $agent->register("my_agent_name", $st_oid, \&agentx_handler);
  }
  $agent->main_loop();

  # Not reached
}

1;

## Local Variables:
## mode: CPerl
## End:
