package Video::DE::Mediathek::LoggerHandler;
use Moose;
use Log::Log4perl;

has 'logger' => (
    is          => 'ro',
    isa         => 'Log::Log4perl::Logger',
    required    => 1,
    lazy        => 1,
    builder     => '_build_logger',
    );

has 'log_filename' => (
    is          => 'ro',
    isa         => 'Str',
    required    => 1,
    default     => '/tmp/mediathek.log',
    );

sub _build_logger {
    my $self = shift;

    my @lines = <DATA>;
    my $config = join( '', @lines );
    
    my $log_filename = $self->log_filename;
    $config =~ s/%log_filename%/$log_filename/s;
    Log::Log4perl->init( \$config );
    return Log::Log4perl->get_logger();
}


1;

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

