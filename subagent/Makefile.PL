use 5.020002;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Snabb::SNMP::Agent',
    VERSION_FROM      => 'lib/Snabb/SNMP/Agent.pm',
    PREREQ_PM         => { SNMP => 5.0404,
                           'NetSNMP::agent' => '5.0404',
                           'NetSNMP::ASN' => '5.0.404',
                           'Net::SNMP' => '6.0.1',
                         },
    EXE_FILES         => [ 'bin/interfaces', 'bin/pseudowire' ],
    ABSTRACT          => 'AgentX-based SNMP sub-agent for Snabb applications',
    AUTHOR            => 'Alexander Gall <gall@switch.ch>',
    #LICENSE           => 'perl',
    #Value must be from legacy list of licenses here
    #http://search.cpan.org/perldoc?Module%3A%3ABuild%3A%3AAPI
);
