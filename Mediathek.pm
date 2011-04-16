package Mediathek;
use strict;
use warnings;

BEGIN { $Class::Date::WARNINGS=0; }

use DBI;
use WWW::Mechanize;
use XML::Twig;
use File::Util;
use File::Spec::Functions;
use YAML::Any qw/Dump/;
use Log::Log4perl;

use Data::Dumper;
use Class::Date qw/date/;
use Format::Human::Bytes;
use Lingua::DE::ASCII;

use IO::Uncompress::Unzip qw(unzip $UnzipError) ;

use Video::Flvstreamer 0.02;

sub new{
    my( $class, $args ) = @_;

    my $self=  {};

    bless $self, $class;

    my $logger = Log::Log4perl->get_logger();
    $self->{logger} = $logger;

    my $mech = WWW::Mechanize->new();
    if( $args->{proxy} ){
        $mech->proxy(['http', 'ftp'], $args->{proxy} )
    }

    if( $args->{agent} ){
        $mech->agent( $args->{agent} );
    }

    if( $args->{cookie_jar} ){
        $mech->cookie_jar( { file => $args->{cookie_jar} } );
    }


    $self->{mech} = $mech;

    foreach( qw/cookie_jar flvstreamer cache_time target_dir sqlite_cache_size/ ){
        if( $args->{$_} ){
            $self->{$_} = $args->{$_};
        }
    }

    # Some defaults

    $self->{flvstreamer} ||= 'flvstreamer';
    $self->{cache_time}  ||= 3600;
    $self->{sqlite_cache_size} ||= 80000;  # Allow sqlite to use 80MB in memory for caching
    $self->{logger}->debug( "Using flvstreamer: $self->{flvstreamer}" );
    $self->{logger}->debug( "Cache time: $self->{cache_time}" );

    if( $self->{sqlite_cache_size} !~ m/^\d*$/ ){
        die( "Invalid number for sqlite_cache_size: $self->{sqlite_cache_size}" );
    }

    my $f = File::Util->new();
    $self->{f} = $f;

    if( ! $args->{cache_dir} || ! -d $args->{cache_dir} ){
        die( "Cannot run without defining cache dir, or cache dir does not exist" );
    }
    $self->{cache_files}->{sources}   = catfile( $args->{cache_dir}, 'sources.xml' );
    $self->{cache_files}->{media}     = catfile( $args->{cache_dir}, 'media.xml' );
    $self->{cache_files}->{media_zip} = catfile( $args->{cache_dir}, 'media.zip' );
    $self->{cache_files}->{db}        = catfile( $args->{cache_dir}, 'mediathek.db' );

    my $flv = Video::Flvstreamer->new( { target_dir  => $args->{target_dir},
                                         timeout     => $args->{timeout},
                                         flvstreamer => $args->{flvstreamer},
                                         socks       => $args->{socks}, 
                                         debug       => $self->{logger}->is_debug(),
                                        } );
    $self->{flv} = $flv;


    if( ! -f $self->{cache_files}->{db} ){
        $self->init_db();
    }
    my $dbh = DBI->connect("dbi:SQLite:dbname=" . $self->{cache_files}->{db},"","");
    if( ! $dbh ){
        die( "DB could not be initialised: #!" );
    }
    # Make UTF compatible
    $dbh->{sqlite_unicode} = 1;

    # turning synchronous off makes SQLite /much/ faster!
    # It might also be responsible for race conditions where a read doesn't see a write which has just happened...
    $dbh->do( "PRAGMA synchronous=OFF" );
    $dbh->do( "PRAGMA cache_size=" . $self->{sqlite_cache_size} );

    $self->{dbh} = $dbh;
    $self->{logger}->debug( "Cache files:\n" . Dump( $self->{cache_files} ) );

    return $self;

}

sub refresh_sources{
    my( $self ) = @_;
    my $f = File::Util->new();


    # Give some debug info about the cache file
    if( $self->{logger}->is_debug() && $self->{cache_files}->{sources} ){
        $self->{logger}->debug( "Cached sources file " . ( -f $self->{cache_files}->{sources} ? 'exists' : 'does not exist' ) );
        if( -f $self->{cache_files}->{sources} ){
            $self->{logger}->debug( "Cached sources file is " . ( time() - $self->{f}->created( $self->{cache_files}->{sources} ) ) . 's old' );
        }
    }

    if( ! $self->{cache_files}->{sources} ){
        die( "Cannot refresh sources without a cache file" );
    }

    if( ! -f $self->{cache_files}->{sources} ||
          ( time() - $self->{f}->created( $self->{cache_files}->{sources} ) > $self->{cache_time} ) ){
        $self->{logger}->debug( "Loading sources from internet" );
        $self->get_url_to_file( 'http://zdfmediathk.sourceforge.net/update.xml', $self->{cache_files}->{sources} );
    }
    $self->{logger}->debug( "Sources XML file is " . 
                              Format::Human::Bytes::base10( $self->{f}->size( $self->{cache_files}->{sources} ) ) );

    $self->{logger}->debug( "Deleting sources table in db" );
    my $sql = 'DELETE FROM sources';
    my $sth = $self->{dbh}->prepare( $sql );
    $sth->execute;

    my $t= XML::Twig->new( twig_handlers =>
                             { Server => \&source_to_db,
                           },
                          );
    $sql = 'INSERT INTO sources ( url, time, tried ) VALUES( ?, ?, 0 )';
    $sth = $self->{dbh}->prepare( $sql );
    $t->{mediathek_sth} = $sth;

    $self->{logger}->debug( "Parsing source XML: $self->{cache_files}->{sources}" );
    $t->parsefile( $self->{cache_files}->{sources} );
    $self->{logger}->debug( "Finished parsing source XML" );
    $t->purge;
    $sth->finish;
}

sub source_to_db{
    my( $t, $section ) = @_;

    my %values;
    ###FIXME - get all children, not just by name
    foreach my $key ( qw/Download_Filme_1 Datum Zeit/ ){
        my $element = $section->first_child( $key );
        if( $element ){
            $values{$key} = $element->text();
        }
    }
    my( $day, $month, $year ) = split( /\./, $values{Datum} );
    my( $hour, $min, $sec ) = split( /:/, $values{Zeit} );
    my $date = Class::Date->new( [$year,$month,$day,$hour,$min,$sec] );
    $t->{mediathek_sth}->execute( $values{Download_Filme_1}, $date );
}

sub refresh_media{
    my( $self ) = @_;

    $self->refresh_sources();

    if( ! $self->{dbh} ){
        die( "Cannot get_media without a dbh" );
    }

    if( ! $self->{cache_files}->{media} ){
        die( "Cannot refresh media without a cache file" );
    }

    # Give some debug info about the cache file
    if( $self->{logger}->is_debug() && $self->{cache_files}->{media} ){
        $self->{logger}->debug( "Cached media file ($self->{cache_files}->{media}) " . ( -f $self->{cache_files}->{media} ? 'exists' : 'does not exist' ) );
        if( -f $self->{cache_files}->{media} ){
            $self->{logger}->debug( "Cached media file is " . ( time() - $self->{f}->created( $self->{cache_files}->{media} ) ) . 's old' );
        }
    }

    if( ! -f $self->{cache_files}->{media} ||
          ( time() - $self->{f}->created( $self->{cache_files}->{media} ) > $self->{cache_time} ) ){

        my $sql = 'SELECT id, url, time FROM sources WHERE tried==0 ORDER BY time DESC LIMIT 1';
        my $sth_select = $self->{dbh}->prepare( $sql );
        $sql = 'UPDATE sources SET tried=1 WHERE url=?';
        my $sth_update = $self->{dbh}->prepare( $sql );
        my $got_media = undef;
      MEDIA_SOURCE:
        do{
            $sth_select->execute();
            my $row = $sth_select->fetchrow_hashref();

            if( ! $row ){
                die( "No url found in sources table" );
            }

            $self->{logger}->debug( "Getting media from internet: $row->{url} ($row->{time})" );
            $self->get_url_to_file( $row->{url}, $self->{cache_files}->{media_zip} );
            $self->{logger}->debug( "Zip file is " . 
                                      Format::Human::Bytes::base10( $self->{f}->size( $self->{cache_files}->{media_zip} ) ) );

            $self->{logger}->debug( "Unzipping media..." );
            my $media_xml;
            # Unzip the file to an the XML string
            if( ! unzip( $self->{cache_files}->{media_zip} => $self->{cache_files}->{media}, Name => ".filme" ) ){
                $self->{logger}->warn( $UnzipError );
                $sth_update->execute( $row->{url} );
                next MEDIA_SOURCE;
            }
            $got_media = 1;
        }while( ! $got_media );
        $sth_select->finish();
        $sth_update->finish();
    }
    $self->{logger}->debug( "Media XML file is " .
                              Format::Human::Bytes::base10( $self->{f}->size( $self->{cache_files}->{media} ) ) );

    $self->{logger}->debug( "Deleting media tables in db" );
    $self->{dbh}->do( 'DELETE FROM channels' );
    $self->{dbh}->do( 'DELETE FROM themes' );
    $self->{dbh}->do( 'DELETE FROM map_media' );
    $self->{dbh}->do( 'DELETE FROM media' );

    my $t= XML::Twig->new( twig_handlers => { Filme => \&media_to_db, },
                          );
    # Prepare the statement handlers
    my $sths = {};
    my $sql = 'INSERT OR IGNORE INTO media ' .
      '( nr, filename, title, url, url_auth, url_hd, url_org, url_rtmp, url_theme ) '.
        'VALUES( ?, ?, ?, ?, ?, ?, ?, ?, ? )';
    $sths->{ins_media} = $self->{dbh}->prepare( $sql );

    $sql = 'INSERT OR IGNORE INTO channels ( channel ) VALUES( ? )';
    $sths->{ins_channel} = $self->{dbh}->prepare( $sql );

    $sql = 'INSERT OR IGNORE INTO themes ( channel_id, theme ) VALUES( ?, ? )';
    $sths->{ins_theme} = $self->{dbh}->prepare( $sql );

    $sql = 'INSERT OR IGNORE INTO map_media ( media_id, theme_id ) VALUES( ?, ? )';
    $sths->{ins_map_media} = $self->{dbh}->prepare( $sql );


    $sql = 'SELECT id AS channel_id FROM channels WHERE channel=?';
    $sths->{sel_channel_id} = $self->{dbh}->prepare( $sql );

    $sql = 'SELECT id AS theme_id FROM themes WHERE channel_id=? AND theme=?';
    $sths->{sel_theme_id} = $self->{dbh}->prepare( $sql );

    $sql = 'SELECT id AS media_id FROM media WHERE url=?';
    $sths->{sel_media_id} = $self->{dbh}->prepare( $sql );

    $t->{mediathek_sths} = $sths;
    $t->{mediathek_logger} = $self->{logger};
    $t->{mediathek_count_inserts} = 0;

    $self->{logger}->debug( "Parsing media XML: $self->{cache_files}->{media}" );
    $t->parsefile( $self->{cache_files}->{media} );
    $self->{logger}->debug( "Finished parsing media XML" );
    $t->purge;

    # Clean up all of the handlers
    foreach( keys( %$sths ) ){
        $sths->{$_}->finish;
    }

    $t->{mediathek_sths} = undef;
    $t->{mediathek_logger} = undef;
    $t->{mediathek_count_inserts} = undef;

    $self->{logger}->debug( __PACKAGE__ . "->refresh_media end" );
}

# <Filme><Nr>0000</Nr><Sender>3Sat</Sender><Thema>3sat.full</Thema><Titel>Mediathek-Beiträge</Titel><Url>http://wstreaming.zdf.de/3sat/veryhigh/110103_jazzbaltica2010ceu_musik.asx</Url><UrlOrg>http://wstreaming.zdf.de/3sat/300/110103_jazzbaltica2010ceu_musik.asx</UrlOrg><Datei>110103_jazzbaltica2010ceu_musik.asx</Datei><Film-alt>false</Film-alt></Filme>
sub media_to_db{
    my( $t, $section ) = @_;

    my %values;
    ###FIXME - get all children, not just by name
    foreach my $key ( qw/Datei Nr Sender Thema Titel Url UrlOrg UrlAuth UrlHD UrlRTMP UrlThema/ ){
        my $element = $section->first_child( $key );
        if( $element ){
            $values{$key} = $element->text();
        }
    }

    foreach( qw/Url Sender Thema Titel/ ){
        if( ! $values{$_} ){
            warn( "$_ not defined for entry $values{Nr}.  Skipping.\n" );
            return undef;
        }
    }

    my( $row, $sql );
    my $sths = $t->{mediathek_sths};
    $sths->{ins_channel}->execute( $values{Sender} );

    $sths->{sel_channel_id}->execute( $values{Sender} );
    $row = $sths->{sel_channel_id}->fetchrow_hashref();
    if( ! $row ){
        die( "Could not find channel_id for $values{Sender} at entry number $values{Nr}" );
    }
    my $channel_id = $row->{channel_id};

    $sths->{ins_theme}->execute( $channel_id, $values{Thema} );
    $sths->{sel_theme_id}->execute( $channel_id, $values{Thema} );
    $row = $sths->{sel_theme_id}->fetchrow_hashref();
    if( ! $row ){
        die( "Could not find themeid for Theme \"$values{Thema}\" and " .
               "Channel \"$values{Sender}\" (channel_id $channel_id) at entry number $values{Nr}" );
    }
    my $theme_id = $row->{theme_id};

    # Add the media data
    #( filename, title, url, url_auth, url_hd, url_org, url_rtmp, url_theme )
    $sths->{ins_media}->execute( $values{Nr}, $values{Datei}, $values{Titel}, $values{Url}, $values{UrlAuth},
                                 $values{UrlHD}, $values{UrlOrg}, $values{UrlRTMP}, $values{UrlThema} );
    $sths->{sel_media_id}->execute( $values{Url} );
    $row = $sths->{sel_media_id}->fetchrow_hashref();
    if( ! $row ){
        die( "Could not find media with url $values{Url}" );
    }
    my $media_id = $row->{media_id};

    # And lastly add the mapping
    $sths->{ins_map_media}->execute( $media_id, $theme_id );

    $section->purge;
}

sub count_videos{
    my( $self, $args ) = @_;
    my $sql = 'SELECT COUNT( DISTINCT( m.id ) ) AS count_videos '.
      'FROM media m ' .
      'JOIN map_media mm ON m.id=mm.media_id ' .
      'JOIN themes t ON t.id=mm.theme_id '.
      'JOIN channels c ON c.id=t.channel_id';

    my( @where_sql, @where_args );
    if( $args->{channel} ){
        push( @where_sql, 'c.channel=?' );
        push( @where_args, $args->{channel} );
    }
    if( $args->{theme} ){
        push( @where_sql, 't.theme=?' );
        push( @where_args, $args->{theme} );
    }
    if( $args->{title} ){
        push( @where_sql, 'm.title=?' );
        push( @where_args, $args->{title} );
    }
    if( scalar( @where_sql ) > 0 ){
        $sql .= ' WHERE ' . join( ' AND ', @where_sql );
    }

    $self->{logger}->debug( "SQL: $sql" );
    $self->{logger}->debug( "SQL Args: " . join( ', ', @where_args ) );
    my $sth = $self->{dbh}->prepare( $sql );
    $sth->execute( @where_args );
    my $row = $sth->fetchrow_hashref();
    return $row->{count_videos};
}

sub list{
    my( $self, $args ) = @_;

    my( @joins, @selects, @where_sql, @where_args );
    push( @selects, 'c.channel' );
    push( @selects, 'c.id AS channel_id' );
    if( $args->{channel} ){
        if( $args->{channel} =~ m/\*/ ){
            $args->{channel} =~ s/\*/\%/g;
            push( @where_sql, 'c.channel LIKE ?' );
        }else{
            push( @where_sql, 'c.channel=?' );
        }
        push( @where_args, $args->{channel} );
    }
    if( $args->{list_all} || $args->{channel} || $args->{theme} || $args->{title} || $args->{media_id} ){
        push( @joins, 'JOIN themes t ON c.id=t.channel_id' );
        push( @selects, 't.theme' );
        push( @selects, 't.id AS theme_id' );
    }
    if( $args->{theme} ){
        if( $args->{theme} =~ m/\*/ ){
            $args->{theme} =~ s/\*/\%/g;
            push( @where_sql, 't.theme LIKE ?' );
        }else{
            push( @where_sql, 't.theme=?' );
        }
        push( @where_args, $args->{theme} );
    }
    if( $args->{list_all} || $args->{title} || $args->{theme} || $args->{media_id} ){
        push( @selects, 'm.id AS media_id' );
        push( @selects, 'm.*' );
        push( @joins, 'JOIN map_media mm ON mm.theme_id=t.id' );
        push( @joins, 'JOIN media m ON mm.media_id=m.id' );
    }
    if( $args->{title} ){
        if( $args->{title} =~ m/\*/ ){
            $args->{title} =~ s/\*/\%/g;
            push( @where_sql, 'm.title LIKE ?' );
        }else{
            push( @where_sql, 'm.title=?' );
        }
        push( @where_args, $args->{title} );
    }
    if( $args->{media_id} ){
        push( @where_sql, 'm.id=?' );
        push( @where_args, $args->{media_id} );
    }


    my $sql = 'SELECT ' . join( ', ',  @selects ) .
      ' FROM channels c ' .
      join( ' ', @joins );
    if( scalar( @where_sql ) > 0 ){
        $sql .= ' WHERE ' . join( ' AND ', @where_sql );
    }

    $self->{logger}->debug( "SQL: $sql" );
    $self->{logger}->debug( "SQL Args: " . join( ', ', @where_args ) );

    my $sth = $self->{dbh}->prepare( $sql );
    $sth->execute( @where_args );
    my $row;
    my $out;
    while( $row = $sth->fetchrow_hashref() ){
        $out->{channels}->{$row->{channel_id}} = $row->{channel};
        if( $row->{theme_id} ){
            $out->{themes}->{$row->{theme_id}} = { theme      => $row->{theme},
                                                   channel_id => $row->{channel_id} };
        }
        if( $row->{media_id} ){
            $out->{media}->{$row->{media_id}} = { title    => $row->{title},
                                                  theme_id => $row->{theme_id},
                                                  url      => $row->{url} };
        }
    }
    return $out;
}

sub get_videos{
    my( $self, $args ) = @_;

    if( ! $self->{target_dir} ){
        die( __PACKAGE__ . " target dir not defined" );
    }

    if( ! -d $self->{target_dir} ){
        die( __PACKAGE__ . " target dir does not exist: $self->{target_dir}" );
    }

    $args->{list_all} = 1;
    my $list = $self->list( $args );

    if( ! $list->{media} ){
        $self->{logger}->warn( "No videos found matching your search..." );
    }

    $self->{logger}->info( "Found " . scalar( keys( %{ $list->{media} } ) ) . " videos to download" );
    
    my $sth = $self->{dbh}->prepare( 'INSERT INTO downloads ( abo_id, path, url, time ) '.
        'VALUES( ?, ?, ?, ? )' );

    foreach( sort( keys( %{ $list->{media} } ) ) ){
        my $video = $list->{media}->{$_};
        my $theme = to_ascii( $list->{themes}->{ $video->{theme_id} }->{theme} );
        my $channel = to_ascii( $list->{channels}->{ $list->{themes}->{ $video->{theme_id} }->{channel_id} } );
        my $target_dir = catfile( $self->{target_dir}, $channel, $theme );
        $target_dir =~ s/\s/_/g;
        $self->{logger}->debug( "Target dir: $target_dir" );
        if( ! -d $target_dir ){
            if( ! $self->{f}->make_dir( $target_dir ) ){
                die( "Could not make target dir: $target_dir" );
            }
        }
        my $title = to_ascii( $video->{title} );
        #TODO: find a module which replaces all bad-in-filename characters
        $title =~ s/\(/_/g;
        $title =~ s/\)/_/g;
        $title =~ s/\//_/g;
        $title =~ s/\W/_/g;
        my $target_path = catfile( $target_dir, $title . '.avi' );
        if( -e $target_path ){
            $self->{logger}->info( sprintf( "Media already downloaded: %s", $target_path ) );
        }elsif( ! $args->{test} ){
            $self->{logger}->info( sprintf( "Getting %s%s || %s || %s", ( $args->{test} ? '>>TEST<< ' : '' ), $channel, $theme, $video->{title} ) );
            if( $video->{url} =~ /^http/ ){
                my @args = ( "/usr/bin/mplayer", "-playlist", to_ascii($video->{url}), 
                    "-dumpstream", "-dumpfile", $target_path );
                $self->{logger}->debug( sprintf( "Running: %s", "@args" ) );
                system( @args ) == 0 or $self->{logger}->warn( sprintf( "%s", $! ) );
            }else{
                $self->{flv}->get_raw( $video->{url}, $target_path );
            }
            
            if( -e $target_path ){
                $sth->execute( -1, $target_path, $video->{url}, date(time) );
            }else{ 
                $self->{logger}->info( sprintf( "Could not download %s", $video->{title} ) );
            }
        }
    }
    $sth->finish();
}

sub add_abo{
    my( $self, $args ) = @_;
    
    if( !$args->{channel} && !$args->{theme} && !$args->{title} ){
        die( "Abo would download all media. Please specify a filter.\n");
    }
  
	my $sth = $self->{dbh}->prepare( 'INSERT INTO abos ( name, channel, theme, ' .
        'title, expires_after) VALUES( ?, ?, ?, ?, ? )' );
	$sth->execute( $args->{name}, $args->{channel}, $args->{theme}, $args->{title},
		$args->{expires} ) or die( "Abo not added.\n" );     
    $self->{logger}->info( "Abo successfully added.\n" );
	$sth->finish();
}

sub del_abo{
    my( $self, $args ) = @_;
    
    $self->{dbh}->do( "DELETE FROM abos WHERE name='$args->{name}'" )
        or die( "Abo not deleted\n" );
    $self->{logger}->info( "Abo successfully deleted\n" );
}

sub list_abos{
    my ( $self ) = @_;

	my $arr_ref = $self->{dbh}->selectall_arrayref( "SELECT name FROM abos ORDER BY name" )
		or die( "An error occured while retrieving abos\n" );

	if( @{$arr_ref} == 0 ){
		print "No abos found\n";
	}
	else{
		print "Abo name\n========\n";
		for( @{$arr_ref} ){
			print "@{$_}\n";
		}
	}
}

sub get_url_to_file{
    my( $self, $url, $filename ) = @_;
    $self->{logger}->debug( "Saving $url to $filename" );
    my $response = $self->{mech}->get( $url );
    if( ! $response->is_success ){
        die( "get failed: " . $response->status_line . "\n" );
    }

    my $write_mode = '>';
    my $binmode = 1;
    if( $filename =~ m/\.xml$/ ){
        $write_mode .= ':encoding(UTF-8)';
        $binmode = undef;
    }

    if( ! open( FH, $write_mode, $filename ) ){
        die( "Could not open file: $filename\n$!\n" );
    }
    if( $binmode ){
        binmode( FH );
    }
    print FH $response->decoded_content;
    close FH;
}

sub init_db{
    my( $self ) = @_;
    if( -f $self->{cache_files}->{db} ){
        $self->{logger}->debug( "Deleting old database" );
        unlink( $self->{cache_files}->{db} );
    }
    my $dbh = DBI->connect("dbi:SQLite:dbname=" . $self->{cache_files}->{db},"","");
    if( ! $dbh ){
        die( "Could not connect to DB during init_db: $!" );
    }
    $self->{logger}->debug( "Reading SQL file in" );

    if( ! open( FH, "<create_db.sql" ) ){
        die( "Could not open create_db.sql: $!" );
    }
    my $line;
    my $sql;
  LINE:
    while( $line = readline( FH ) ){
        if( $line =~ m/^\s*$/ || $line =~ m/^\-\-/ || $line =~ m/^\#/ ){
            next LINE;
        }
        chomp( $line );
        $sql .= $line;
    }
    close FH;

    my @commands = split( /;/, $sql );
    foreach( @commands ){
        $self->{logger}->debug( "SQL: $_\n" );
        $dbh->do( $_ );
    }
    $dbh->disconnect;
}


1;
