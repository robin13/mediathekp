#!/usr/bin/perl
use strict;
use warnings;
use Mediathek;
use Getopt::Long;
use Log::Log4perl;
use YAML::Any qw/Dump LoadFile DumpFile/;
use Encode;
use File::Util;
use Data::Dumper;

$SIG{'INT'} = 'cleanup';
$SIG{'QUIT'} = 'cleanup';

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
                          'test'          => \$args->{test},
                          'tries=i'       => \$args->{tries},

                        # Filters
                          'channel=s'     => \$args->{channel},
                          'theme=s'       => \$args->{theme},
                          'title=s'       => \$args->{title},
                          'id=i'          => \$args->{id},

                        # Required for downloading
                          'target_dir=s'  => \$args->{target_dir},

                        # Actions: refresh_media, download, count, list, 
                        # add_abo, del_abo, run_abo, list_abos
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

$logger->debug( "Args:\n" . Dump( $args ) );

# Pass the memory usage monitor to Mediathek
my $media = Mediathek->new( $args );

if( $args->{action} ){
    if( $args->{action} eq 'refresh_media' ){
        # Refresh the media listing?
        $media->refresh_media();
    }elsif( $args->{action} eq 'download' ){
        # Download videos
        $media->get_videos( { channel  => $args->{channel},
                              theme    => $args->{theme},
                              title    => $args->{title},
                              media_id => $args->{id},
                              test     => $args->{test},
                          } );
    }elsif( $args->{action} eq 'count' ){
        # Count the number of videos
        my $count_videos = $media->count_videos( { channel  => $args->{channel},
                                                   theme    => $args->{theme},
                                                   title    => $args->{title},
                                                   media_id => $args->{id},
                                               } );
        print "Number of videos matching: $count_videos\n";
    }elsif( $args->{action} eq 'list' ){
        print list( $media );
    }elsif( $args->{action} eq 'init_db' ){
        $media->init_db();
    }elsif( $args->{action} =~ /^add_abo,(\w+),(\d+)/ ){
        $media->add_abo( { name => $1,
                           expires => $2,
                           channel => $args->{channel},
                           theme => $args->{theme},
                           title => $args->{title},
                       } );
    }elsif( $args->{action} =~ /^del_abo,(\w+)/ ){
        print "del_abo: $1\n";
    }elsif( $args->{action} =~ /^run_abo,(\w+)/ ){
        print "run_abo: $1\n";
    }elsif( $args->{action} eq 'list_abos' ){
        print "list_abos\n";
    }else{
        die( "Unknown action: $args->{action}" );
    }
}

$logger->debug( "Just before natural exit" );

exit( 0 );

sub get_log_filename{
    return $args->{cache_dir} . $f->SL() . 'debug.log';
}

sub cleanup{
    my( $sig ) = @_;
    $logger->warn( "Caught a SIG$sig--shutting down" );
    exit( 0 );
}

sub list{
    my( $media ) = @_;
    my $list = $media->list({ channel => $args->{channel},
                              theme   => $args->{theme},
                              title   => $args->{title},
                              media_id => $args->{id},
                            } );
    if( ! $list or ! $list->{channels} ){
        return "No matches found\n";
    }

    if( ! $list->{themes} ){
        return list_channels( $list );
    }elsif( ! $list->{media} and $list->{themes} ){
        return list_themes( $list );
    }elsif( $list->{media} and $list->{themes} ){
        return list_titles( $list );
    }else{
        return "No suitable list to print...\n" . Dumper( $list ) . "\n";
    }
}

sub list_channels{
    my $list = shift;

    my $fmt =  ( ' ' x 4 ) . "%s\n";
    my $rtn = sprintf( $fmt, 'Channel' );
    $rtn .= sprintf( $fmt, '=======' );
    foreach( sort ( values( %{ $list->{channels} } ) ) ){
        $rtn .= sprintf $fmt, $_;
    }
    return $rtn;
}

sub list_themes{
    my $list = shift;

    # Find length of longest channel name
    my $max_channel = length( "Channel" );
    foreach( keys( %{ $list->{channels} } ) ){
        if( ! $max_channel || length( $list->{channels}->{$_} ) > $max_channel ){
            $max_channel = length( $list->{channels}->{$_} );
        }
    }

    my $fmt =  ( ' ' x 4 ) . '%-' . $max_channel . "s || %s\n";
    my $rtn = sprintf( $fmt, 'Channel', 'Theme' );
    $rtn .= sprintf( $fmt, '=======', '=====' );
    foreach my $channel_id ( sort{ $list->{channels}->{$a} cmp $list->{channels}->{$b} }( keys( %{ $list->{channels} } ) ) ){
        foreach my $theme_id ( sort{ $list->{themes}->{$a}->{theme} cmp $list->{themes}->{$b}->{theme} }( keys( %{ $list->{themes} } ) ) ){
            $rtn .= sprintf( $fmt, $list->{channels}->{$channel_id}, $list->{themes}->{$theme_id}->{theme} );
        }
    }
    return $rtn;
}

sub list_titles{
    my $list = shift;
    # Find length of longest channel name
    my $max_channel = length( 'Channel' );
    foreach( keys( %{ $list->{channels} } ) ){
        if( ! $max_channel || length( $list->{channels}->{$_} ) > $max_channel ){
            $max_channel = length( $list->{channels}->{$_} );
        }
    }

    # Find length of longest theme
    my $max_theme = length( 'Theme' );
    foreach( keys( %{ $list->{themes} } ) ){
        if( ! $max_theme || length( $list->{themes}->{$_}->{theme} ) > $max_theme ){
            $max_theme = length( $list->{themes}->{$_}->{theme} );
        }
    }

    my $fmt =  ( ' ' x 4 ) . '%-4s || %-' . $max_channel . "s || %-" . $max_theme . "s || %s\n";
    my $rtn = sprintf( $fmt, 'ID', 'Channel', 'Theme', 'Title' );
    $rtn .= sprintf( $fmt, '==', '=======', '=====', '=====' );
    foreach my $channel_id ( sort{ $list->{channels}->{$a} cmp $list->{channels}->{$b} }( keys( %{ $list->{channels} } ) ) ){
        foreach my $theme_id ( sort{ $list->{themes}->{$a}->{theme} cmp $list->{themes}->{$b}->{theme} }( keys( %{ $list->{themes} } ) ) ){
            if( $list->{themes}->{$theme_id}->{channel_id} eq $channel_id ){
                foreach my $media_id ( sort{ $list->{media}->{$a}->{title} cmp $list->{media}->{$b}->{title} }( keys( %{ $list->{media} } ) ) ){
                    if( $list->{media}->{$media_id}->{theme_id} eq $theme_id ){
                        $rtn .= sprintf( $fmt, $media_id, $list->{channels}->{$channel_id}, $list->{themes}->{$theme_id}->{theme}, $list->{media}->{$media_id}->{title} );
                    }
                }
            }
        }
    }
    return $rtn;
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
  --tries        The number of tries Video::Flvstreamer should make per video
                 There are often interruptions during a download, so a high number
                 like 50 is pretty safe.  Default is 10
  --help         Print this help out

Action options (--action ACTION):
  count          Count number of videos matching your search
  list           List the videos matching your search
  download       Download the videos matching your search
  refresh_media  Refresh your database from the internet
  init_db        (re)initialise your database (!!delete everything in DB!!)

Search options:
      One or more search options can be given
      !! WARNING !! If you use the action --download, and no search
      options, you will download ALL the videos...
  --channel     Limit action to this channel
  --theme       Limit action to this theme
  --title       Limit action to this title
  --id          Limit action to the media entry with this id
  Search options can be explicit: Arte.DE
  or contain wildcards: "Doku*"
};

}
