use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'TV::Mediathek',
    AUTHOR              => q{Robin Clarke <perl@robinclarke.net>},
    VERSION_FROM        => 'lib/TV/Mediathek.pm',
    ABSTRACT_FROM       => 'lib/TV/Mediathek.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    EXE_FILES	=> [ 'bin/mediathekp' ],
    PREREQ_PM => {
	'Class::Date'			=> 0,
	'DBD::SQLite'			=> 0,
	'DBI'				=> 0,
	'Data::Dumper'			=> 0,
	'Encode'			=> 0,
	'ExtUtils::MakeMaker'		=> 0,
	'File::HomeDir'			=> 0,
	'File::Spec::Functions'		=> 0,
	'File::Util'			=> 0,
	'Format::Human::Bytes'		=> 0,
	'Getopt::Long'			=> 0,
	'IO::Uncompress::AnyUncompress'	=> 0,
	'Lingua::DE::ASCII'		=> 0,
	'Log::Log4perl'			=> 0,
	'Moose'				=> 0,
	'MooseX::Log::Log4perl'		=> 0,
	'Pod::Usage'			=> 0,
	'Test::More'			=> 0,
	'Video::Flvstreamer'		=> 0.03,
	'WWW::Mechanize'		=> 0,
	'XML::Twig'			=> 0,
	'YAML::Any'			=> 0,
    },
    (! eval { ExtUtils::MakeMaker->VERSION(6.46) } ? () :
     (META_ADD => {
      resources => {
      homepage   => 'https://github.com/robin13/mediathekp',
      repository => 'https://github.com/robin13/mediathekp',
      bugtracker => 'https://github.com/robin13/mediathekp/issues',
      },
      })
    ),
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'TV-Mediathek-*' },
);
