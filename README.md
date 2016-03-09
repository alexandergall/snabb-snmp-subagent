# snabb-snmp-subagent

This package provides AgentX-based SNMP subagents for Snabb Switch
applications (https://github.com/SnabbCo/snabbswitch).  Those
applications don't provide an SNMP agent themselves.  Instead, they
store the raw SNMP objects in shared memory segments.

The subagents provided by this package register themselves with a
local SNMP agent via the AgentX protocol to serve particular branches
of the OID tree.  The objects within those branches are fetched from
the memory segments shared with the Snabb applications.

## Instance ID Creation

The Snabb applications have no concept of actual OIDs and, in
particular, the structure of tables.  They only know about the name of
an object (e.g. `ifDescr`) and its type (e.g. an octet string).  It is
the responsibility of the subagent to construct the proper OID for a
particular instance of an object (for a scalar object, this reduces to
simply appending `.0` to the OID).  For this purpose, each conceptual
table that is served by a subagent must be associated with an
_indexer_, which creates the instance ID for any object that is part
of the table.  In many cases, some of the indices of a table can be
constructed from the objects that are part of the same memory segment
as the object itself, like `pwEnetPwInstance` for the `pwEnetTable`.
Other indices are either created on-the-fly, like `pwIndex`, or from a
static configuration, like `ifIndex` as explained below.

## Handling of the SNMP `TimeTicks` type

The `TimeTicks` data type is defined as
```
a non-negative integer which represents the time, modulo 2^32
(4294967296 decimal), in hundredths of a second between two epochs
```

The representation of a time interval is straight forward, but that of
an absolute point in time, called the `TimeStamp` textual convention
for the `TimeTicks` type is a bit peculiar.  It is defined as the
value of the `sysUpTime` object at that point in time, where
`sysUpTime` itself counts the time ticks since the SNMP agent was
started.

To simplify the handling of objects of this type, the subagents make
use of the following conventions.

When a subagent starts, it queries the master agent for the value of
`sysUpTime` (it uses the community string `snabb` for that purpose,
see the section on [configuring the `snmpd`
daemon](#disable-built-in)) and calculates the UNIX time stamp of the
point in time when `sysUpTime` was 0, i.e.

```
sysUpTime_base = currenttime() - sysUptime*100
```

where `currenttime()` returns the number of seconds since the UNIX
epoch.

When a Snabb process needs to store an object of time `TimeStamp`, it
allocates an auxiliary object whose name is obtained by adding the
prefix `_X_` and suffix `_TimeAbs` to the name of the object.  For
example, the name of the auxiliary object for the object
`pwCreateTime` is called `_X_pwCreateTime_TimeAbs`.

The auxiliary object has the fixed type of a 64-bit integer in
host-byte order.  The Snabb process simply stores the time stamp as a
regular UNIX time stamp (e.g. by calling `currenttime()`) in the
auxiliary variable and leaves the original object untouched.

When the subagent receives a query for the object
(e.g. `pwCreateTime`), it reads the value of the auxiliary object
instead.  It then calculates

```
timeStamp = 100*(stamp_aux - sysUpTime_base)
```

where `stamp_aux` is the value of the auxiliary object.  This value is
returned as the value of the original object being queried.

The upshot is that the snabb process doesn't have to worry about
`sysUpTime` at all and can simply store raw UNIX time stamps.

Objects of type `TimeTicks` which use the `TimeTicks` syntax and
represent the interval between a fixed time in the past and the
current time are handled by an auxiliary object with prefix `_X_` and
suffix `_TimeBase`.  The Snabb process stores the UNIX time of the
past event in the auxiliary object.  The subagent calculates the
difference of that time stamp and the current time and returns the
result as the value of the original object.  An example of this type
is given by the object`pwUpTime`, which specifies the time since the
pseudowire's `pwOperStatus` changed to the value `Up`.

## Supported MIBS

### <a name="interface_agent">`interface` Subagent</a>

The `interface` subagent supports the following MIBS or parts thereof

   * `interfaces`  (.1.3.6.1.2.1.2)
   * From `ifMIB`  (.1.3.6.1.2.1.31) 
      * `ifXTable` (.1.3.6.1.2.1.31.1.1)

They provide access to the interfaces controlled by Snabb
applications.  Note that running this subagent requires that the
built-in versions of these MIBs need to be disabled in the SNMP agent,
i.e. interfaces controlled by the Linux kernel are no longer visible
by that agent, also see the section on [configuring the `snmpd`
daemon](#disable-built-in).

Within these MIBs, each interface is assigned a unique index called
the `ifIndex`, which is used to address the rows in the tables.  This
assignment is done statically in a text file which needs to be passed
to all subagents that need it.  This file contains lines of the form

```
<PCI-address> <integer>
```

where `<PCI-address>` is the full PCI address of the NIC,
e.g. `0000:01:00.0` and `<integer>` is an integer that represents the
`ifIndex` which is assigned to the interface.

A Snabb application has no knowledge of the index assigned to its
interfaces.  It stores all objects associated with a particular
interface in the same shared memory segment, which must include the
full PCI address of the interface as value for the `ifDescr` object.

When the `interface` subagent parses such a memory segment, it
performs a lookup of the value of the `ifDescr` object in the static
interface table to obtain the `ifIndex` for the interface to construct
the full instance ID for all objects in the segment.

### `pseudowire` Subagent

The `pseudowire` subagent supports parts of the following MIBs or
parts thereof

   * From `cpwVcMIB` (.1.3.6.1.4.1.9.10.106)
      * `cpwVcTable` (.1.3.6.1.4.1.9.10.106.1.2)
   * From `pwStdMIB` (.1.3.6.1.2.1.10.246)
      * `pwTable` (.1.3.6.1.2.1.10.246.1.2)
   * From `cpwVcEnetMIB` (.1.3.6.1.4.1.9.10.108)
      * `cpwVcEnetTable` (.1.3.6.1.4.1.9.10.108.1.1)
   * From `pwEnetStdMIB`  (1.3.6.1.2.1.180)
      * `pwEnetTable` (1.3.6.1.2.1.180.1.1)

All objects that belong to a particular pseudowire are stored in the
same shared memory segment by the Snabb application.  The `pseudowire`
agent maintains a monotonically increasing counter to enumerate the
pseudowires.  It is increased each time a new memory segment is read.
This counter is used as the `pwIndex` to identify the conceptual row
assigned to the pseudowire in the `cpwVcTable` and `pwTable` tables.

## Configuration

### Command Line Options

All subagents support the following options

   * `--check-interval`: the interval in seconds, at which the agent
     re-reads the shared memory segments in the directory specified by
     `--shmem-dir`
     
   * `--shmem-dir`: the path to a directory in which shared memory
     segments created by a Snabb process can be found

Subagents using MIBs which are not part of the standard library of the
`net-snmp` package (`pseudowire`, referenced through the `Net::SNMP`
Perl module) must supply a directory (or list of directories)
containing the MIB files using the option

   * `--mibs-dirs`: a list of directories containing MIB definitions
     in the syntax described in `snmpcmd(1)`
     
Subagents that need access to the `ifIndex` mapping (`interface` and
`pseudowire`) accept the option

   * `--ifindex`: the path to a file which holds the static mapping of
     PCI addresses to `ifIndex` values as shown in the [description of
     the `interface` subagent](#interface_agent)

### `snmpd` Configuration

#### Enabling AgentX support

To enable AgentX support in `snmpd`, add the following to the
configuration file (e.g. `/etc/snmp/snmpd.conf`)

```
master agentx
agentXSocket  tcp6:[::1]:705
```

Each subagent also requires a configuration file containing the line

```
agentXSocket  tcp6:[::1]:705
```

These files must be located in the state directory of the `net-snmp`
package, usually `/var/lib/net-snmp` and named like the subagent with
suffix `.conf`, e.g. `interface.conf` and `pseudowire.conf`.

#### Add `snabb` Community to access `sysUpTime`

As explained above, each subagent must query the master agent for the
value of the `sysUpTime` object with the fixed community string
`snabb`.  The following configuration in `snmpd.conf` enables this
community to access only `sysUpTime` via `localhost`

```
view sysUpTime included .1.3.6.1.2.1.1.3
rocommunity snabb 127.0.0.1 -V sysUpTime
rocommunity6 snabb ::1 -V sysUpTime
```

#### <a name="disable-built-in">Disabling built-in MIBs</a>

The `interface` subagent takes over the complete `interface` and
`ifMIB` MIBs but the standard `snmpd` provides those MIBs itself for
the local interfaces.  This conflict is resolved by starting `snmpd`
with the option `-I -ifTable` at the price that the SNMP objects of
the local interfaces are no longer available.

If access to the built-in MIBs is required, a separate instance of
`snmpd` needs to be started, either by choosing a different UDP port or
by binding to a different local address (e.g. a loopback address).
