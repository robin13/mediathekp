package TV::Mediathek::LoggerConfig;
use Moose;
use MooseX::Log::Log4perl;
use Log::Log4perl;

=head1 NAME

TV::Mediathek::LoggerConfig - Initialise with a default logger configuration, incase the client hasn't done something cleverer

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

TODO: RCL 2012-01-26 Documentation

=cut

has 'log_filename' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => '/tmp/mediathek.log',
);

=head2 init_logger

TODO: RCL 2012-01-26 Documentation

=cut
sub init_logger {
    my $self = shift;

    my @lines = <DATA>;
    my $config = join( '', @lines );

    my $log_filename = $self->log_filename;
    $config =~ s/%log_filename%/$log_filename/s;
    Log::Log4perl->init_once( \$config );
}

1;

=head1 AUTHOR

Robin Clarke, C<< <perl at robinclarke.net> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 Robin Clarke.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

__DATA__
log4perl.rootLogger=DEBUG, Screen, File
     
log4perl.appender.File                            = Log::Log4perl::Appender::File
log4perl.appender.File.mode                       = clobber
log4perl.appender.File.filename                   = %log_filename%
log4perl.appender.File.layout                     = PatternLayout
log4perl.appender.File.layout.ConversionPattern   = [%d] %-5p > %m%n

### Screen output configuration
# Just show log entries of the level INFO or above
#log4perl.appender.Screen.Threshold                = INFO

# Switch these if coloured doesn't work for your terminal
log4perl.appender.Screen                          = Log::Log4perl::Appender::ScreenColoredLevels
#log4perl.appender.Screen                          = Log::Log4perl::Appender::Screen

log4perl.appender.Screen.stderr                   = 0
log4perl.appender.Screen.layout                   = PatternLayout
log4perl.appender.Screen.layout.ConversionPattern = %-10r %-5p > %m%n

