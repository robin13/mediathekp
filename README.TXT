mediathek is a perl clone of Mediathek:
http://zdfmediathk.sourceforge.net/

It takes the XML file made available by that project, and loads it into a local SQLite database for better access to the data.

Searches can then be carried out, and the videos downloaded.

See all the options:
./mediathek.pl --help

INSTALL

Required perl modules:
DBI
DBD::SQLite
WWW::Mechanize
XML::Twig
File::Util
File::Spec::Functions
YAML::Any
Log::Log4perl
Data::Dumper
Class::Date
Memory::Usage
Format::Human::Bytes
IO::Uncompress::Unzip
Video::Flvstreamer
Getopt::Long
Encode

install with cpan:
cpan DBD::SQLite DBI WWW::Mechanize XML::Twig File::Util File::Spec::Functions YAML::Any Log::Log4perl Data::Dumper Class::Date Memory::Usage Format::Human::Bytes IO::Uncompress::Unzip Video::Flvstreamer Getopt::Long Encode

install modules with cpanp
cpanp DBD::SQLite DBI WWW::Mechanize XML::Twig File::Util File::Spec::Functions YAML::Any Log::Log4perl Data::Dumper Class::Date Memory::Usage Format::Human::Bytes IO::Uncompress::Unzip Video::Flvstreamer Getopt::Long Encode



BASIC USAGE

./mediathek.pl --cache_dir /path/to/cache --

