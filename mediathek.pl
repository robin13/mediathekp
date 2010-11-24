#!/usr/bin/perl
use strict;
use warnings;
use Mediathek;
use Getopt::Long;
use Log::Log4perl;
use YAML::Any qw/Dump LoadFile DumpFile/;
use Encode;
use File::Util;

$SIG{'INT'} = 'cleanup';
$SIG{'QUIT'} = 'cleanup';

my $mu = Memory::Usage->new();
$mu->record( "Starting application at " . localtime() );

my $args = {};
my $result = GetOptions ( 'agent=s'       => \$args->{agent},
                          'cache_dir=s'   => \$args->{cache_dir},
                          'cache_time=i'  => \$args->{cache_time},
                          'cookie_jar=s'  => \$args->{cookie_jar},
                          'timeout=i'     => \$args->{timeout},
                          'flvstreamer=s' => \$args->{flvstreamer},
                          'proxy=s'       => \$args->{proxy},
                          'socks=s'       => \$args->{socks},
                          'config=s'      => \$args->{config},

                        # Filters
                          'channel=s'     => \$args->{channel},
                          'theme=s'       => \$args->{theme},
                          'title=s'       => \$args->{title},

                        # Required for downloading
                          'target_dir=s'  => \$args->{target_dir},

                        # Actions: refresh_media, download, count, list
                          'action=s'      => \$args->{action},

                        # Help
                          'help'          => \$args->{help},
                          );


if( ! $result ){
    die( "Illegal arguments...\n" );
}

if( $args->{help} ){
    usage();
    exit( 0 );
}



if( $args->{config} && -f $args->{config} ){
    eval{
        my $load_args = LoadFile( $args->{config} );
        foreach( keys( %$load_args ) ){
            $args->{$_} = $load_args->{$_};
        }
    };
    if( $@ ){
        die( "Could not load config from $args->{config}: $@\n" );
    }
}

my $f = File::Util->new();
$args->{agent}      ||= 'Mediathek-PL/0.2';
$args->{cache_dir}  ||= '/tmp/mediathek_cache';
$args->{cache_time} ||= 0;
$args->{cookie_jar} ||= $args->{cache_dir} . $f->SL() . 'cookie_jar.dat';

if( ! -d $args->{cache_dir} ){
    warn( "Need cache_dir to be defined and exist\n" );
    usage();
    exit;
}

Log::Log4perl->init( 'log.conf' );
my $logger = Log::Log4perl->get_logger();

DumpFile( 'last_config.yaml', $args );
$logger->debug( "Args:\n" . Dump( $args ) );

# Pass the memory usage monitor to Mediathek
$args->{mu} = $mu;
$mu->record( "Before initialising Mediathek" );
my $media = Mediathek->new( $args );
$mu->record( "After initialising Mediathek" );

if( $args->{action} ){
    if( $args->{action} eq 'refresh_media' ){
        # Refresh the media listing?
        $media->refresh_media();
    }elsif( $args->{action} eq 'download' ){
        # Download videos
        $media->get_videos( { channel => $args->{channel},
                              theme   => $args->{theme},
                              title   => $args->{title},
                          } );
    }elsif( $args->{action} eq 'count' ){
        # Count the number of videos
        my $count_videos = $media->count_videos( { channel => $args->{channel},
                                                   theme   => $args->{theme},
                                                   title   => $args->{title},
                                               } );
        print "Number of videos matching: $count_videos\n";
    }elsif( $args->{action} eq 'list' ){
        # List videos meeting criteria
        print list_videos( $media );
    }elsif( $args->{action} eq 'init_db' ){
        $media->init_db();
    }else{
        die( "Unknown action: $args->{action}" );
    }
}

$logger->debug( "Just before natural exit" );
$mu->report( "Just before natural exit" );
dump_memory_report();

exit( 0 );

sub get_log_filename{
    return $args->{cache_dir} . $f->SL() . 'debug.log';
}

sub cleanup{
    my( $sig ) = @_;
    $logger->warn( "Caught a SIG$sig--shutting down" );
    $mu->report( "Killed with sig $sig" );
    dump_memory_report();
    exit( 0 );
}

sub dump_memory_report{
    # Write the memory report to file
    my $f = File::Util->new();
    my $memory_report_file = $args->{cache_dir} . $f->SL() . 'memory_report.log';
    if( open( FH, ">$memory_report_file" ) ){
        print FH $mu->report();
        close FH;
        $logger->info( "Wrote memory report to $memory_report_file" );
    }else{
        warn( "Couldn't write the memory usage report: $!" );
    }
}

sub list_videos{
    my( $media ) = @_;
    my $list = $media->list( { channel => $args->{channel},
                                      theme   => $args->{theme},
                                      title   => $args->{title},
                                  } );

    # Find out the max width of each column
    my %max;
    my $video_count = 0;
    my @rows;
    foreach my $channel( keys( %$list ) ){
        ###FIXME Use a Mediathek::Video object here
        if( ! $max{channel} || length( $channel ) > $max{channel} ){
            $max{channel} = length( $channel );
        }
        foreach my $theme( keys( %{ $list->{$channel} } ) ){
            if( ! $max{theme} || length( $theme ) > $max{theme} ){
                $max{theme} = length( $theme );
            }
            foreach my $title( keys( %{ $list->{$channel}->{$theme} } ) ){
                if( ! $max{title} || length( $title ) > $max{title} ){
                    $max{title} = length( $title );
                }
                $video_count++;
                if( ! $max{id} || length( $list->{$channel}->{$theme}->{$title} ) > $max{id} ){
                    $max{id} = length( $list->{$channel}->{$theme}->{$title} );
                }
                push( @rows, [ $list->{$channel}->{$theme}->{$title}, $channel, $theme, $title ] );
            }
        }
    }
    foreach( keys( %max ) ){
        $max{$_} += 2;
    }
    my $format = "%$max{id}s %-$max{channel}s %-$max{theme}s %-$max{title}s\n";
    my $list_string = sprintf( $format, 'ID', 'Channel', 'Theme', 'Title' );
    foreach my $row( @rows ){
        $list_string .= sprintf( $format, @$row )
    }
    return $list_string;
}

sub usage{
    print qq{Usage:
  ./mediathek.pl [options]

Required Options:
  --cache_dir   Cache directory to keep downloaded XMLs, zip files and database
  --target_dir  If you use the action --download, where videos are downloaded to


Optional options
  --agent        User agent I should pretend to be. (Default Mediathek-PL/0.2)
  --cache_time   Time for which downloaded files should be cached. (Default: 0)
  --cookie_jar   Store your cookies somewhere else (Default in cache_dir)
  --timeout      Seconds timeout for flvstreamer.  (Default: 10)
  --flvstreamer  Location of your flvstreamer binary (Default: /usr/bin/flvstreamer)
  --proxy        http Proxy to use (e.g. http://proxy:8080)
                 flvstreamer can only work through a socks proxy!
  --socks        Socks proxy to use for flvstreamer
  --config       Load settings from a config file:
                 you can put all the options listed here in a config file!
  --help         Print this help out

Action options:
  --count          Count number of videos matching your search
  --list           List the videos matching your search
  --download       Download the videos matching your search
  --refresh_media  Refresh your database from the internet
  --init_db        (re)initialise your database (!!delete everything in DB!!)

Search options:
      One or more search options can be given
      !! WARNING !! If you use the action --download, and no search
      options, you will download ALL the videos...
  --channel     Limit action to this channel
  --theme       Limit action to this theme
  --title       Limit action to this title
};

}
