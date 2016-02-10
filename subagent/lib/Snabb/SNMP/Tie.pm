package Snabb::SNMP::Tie;

use 5.020002;
use strict;
use warnings;
require Tie::Scalar;
use SNMP;
use Snabb::SNMP::Agent qw($sysUpTime_base);
require Exporter;

our @ISA = qw(Exporter Tie::Scalar);

sub TIESCALAR {
  my ($class, $segment, $name, $handler) = @_;
  exists $segment->{objs}{$name} or
    die "Object $name not present in segment $segment->{name} ($segment->{file})";
  my $self = { segment => $segment,
	       obj => $name,
	       handler => $handler };
  return bless($self, $class);
}

package Snabb::SNMP::Tie::INTEGER;

our @ISA = qw(Snabb::SNMP::Tie);

sub FETCH {
  my ($self) = @_;
  my $obj = $self->{segment}{objs}{$self->{obj}};
  $obj->{length} == 4 or die
    "Bad field length for INTEGER, expected 4, got $obj->{length}";
  my $value = unpack("L", substr(${$self->{segment}{mmap}}, $obj->{offset}, $obj->{length}));
  if (defined $self->{handler}) {
    return $self->{handler}($value, $self->{obj}, $self->{segment});
  }
  return $value;
}

package Snabb::SNMP::Tie::INTEGER64;

our @ISA = qw(Snabb::SNMP::Tie);

sub FETCH {
  my ($self) = @_;
  my $obj = $self->{segment}{objs}{$self->{obj}};
  $obj->{length} == 8 or die
    "Bad field length for INTEGER64, expected 8, got $obj->{length}";
  my $value = unpack("Q", substr(${$self->{segment}{mmap}}, $obj->{offset}, $obj->{length}));
  if (defined $self->{handler}) {
    return $self->{handler}($value, $self->{obj}, $self->{segment});
  }
  return $value;
}

package Snabb::SNMP::Tie::OCTETSTR;

our @ISA = qw(Snabb::SNMP::Tie);

sub FETCH {
  my ($self) = @_;
  my $obj = $self->{segment}{objs}{$self->{obj}};
  my $mmap = ${$self->{segment}{mmap}};
  my $len = unpack("S", substr($mmap, $obj->{offset}, 2));
  my $value = substr($mmap, $obj->{offset}+2, $len);
  if (defined $self->{handler}) {
    return $self->{handler}($value, $self->{obj}, $self->{segment});
  }
  return $value;
}

package Snabb::SNMP::Tie::TICKS;

our @ISA = qw(Snabb::SNMP::Tie::INTEGER);

sub FETCH {
  my ($self) = @_;
  my $stamp = $self->SUPER::FETCH();
  my $syntax = $self->{segment}{objs}{$self->{obj}}{oid_node}->{syntax};
  if ($syntax eq 'TimeStamp') {
    my $aux_name = "_X_".$self->{obj}."_TimeAbs";
    my $aux_obj = $self->{segment}{objs}{$aux_name};
    if (defined $aux_obj) {
      ## $stamp is an absolute time stamp.  Convert it to
      ## the notion of sysUpTime
      $aux_obj->{length} == 8 or die
	"Wrong size of TimeStamp aux variable $aux_name";
      my $stamp_abs = unpack("Q", substr(${$self->{segment}{mmap}},
					 $aux_obj->{offset},
					 $aux_obj->{length}));
      ## TimeTicks are in units of 1/100 seconds while the auxiliary
      ## variable uses regular Unix time stamps in units of seconds.
      $stamp = 100*($stamp_abs - $Snabb::SNMP::Agent::sysUpTime_base);
    }
  } else {

    ## The syntax is TimeTicks.  If the auxiliary variable with suffix
    ## "_TicksBase" exists, the ticks are calculated as the difference
    ## between that time stamp and the current time.
    my $aux_name = "_X_".$self->{obj}."_TicksBase";
    my $aux_obj = $self->{segment}{objs}{$aux_name};
    if (defined $aux_obj) {
      $aux_obj->{length} == 8 or die
	"Wrong size of TimeStamp aux variable $aux_name";
      my $stamp_abs = unpack("Q", substr(${$self->{segment}{mmap}},
					 $aux_obj->{offset},
					 $aux_obj->{length}));
      if ($stamp_abs != 0) {
	$stamp = 100*(time() - $stamp_abs);
      }
    }
  }
  return $stamp;
}

1;

## Local Variables:
## mode: CPerl
## End:
