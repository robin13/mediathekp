package TV::Mediathek;
use Moose;
with 'MooseX::Log::Log4perl';

BEGIN { $Class::Date::WARNINGS = 0; }

use DBI;
use WWW::Mechanize;
use XML::Twig;
use File::Util;
use File::Spec::Functions;
use YAML::Any qw/Dump/;

use Data::Dumper;
use Class::Date qw/date/;
use Format::Human::Bytes;
use Lingua::DE::ASCII;

use IO::Uncompress::AnyUncompress qw(anyuncompress $AnyUncompressError);

use Video::Flvstreamer 0.03;
use TV::Mediathek::LoggerConfig;

=head1 NAME

TV::Mediathek - Access to Mediathek

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

List and download TV programs from German and French public TV Mediathek repositories.

Based on (and using some resources from) the original Java MediathekView script:
http://zdfmediathk.sourceforge.net/index.html

=head1 METHODS

=head2 new

Create new instance of TV::Mediathek

=head3 PARAMS

=over 2

=item proxy <Str>

Address of proxy server to use.  e.g. http://proxy.example.com:8001/

Default: undef

=item socks <Str>

Address of socks server to use for download.

Default: undef

=item timeout <Int>

Timeout in seconds while downloading video

Default: 10

=item agent <Str>

User agent string to use.

Default: LWP::UserAgent default

=item cookie_jar <Str>

File to use as a cookie jar

Default: undef

=item mech <WWW::Mechanize>

If you already have a WWW::Mechanize object, you can pass it here, otherwise one will be created for you

=item flvstreamer_binary <Str>

Path to flvstreamer binary

Default: 'flvstreamer'

=item cache_time <Int>

Time in seconds to read from cached sources before refreshing.

Default: 3600

=item sql_cache_size <Int>

Set memory in bytes  which SQLite can use for caching.

Default: 80000

=item cache_dir <Str>

Directory to cache files in

Required.  No Default.

=item target_dir <Str>

Directory to which video files should be saved

=item date_in_filename <Bool>

Should the date of the programme be included in the filename.

With: 2011-10-22_Mit_offenen_Karten.avi

Without: Mit_offenen_Karten.avi

Default: 1

=back

=cut

has 'proxy'              => ( is => 'ro', isa => 'Str', );
has 'socks'              => ( is => 'ro', isa => 'Str', );
has 'timeout'            => ( is => 'ro', isa => 'Int', required => 1, default => 10  );
has 'agent'              => ( is => 'ro', isa => 'Str', );
has 'cookie_jar'         => ( is => 'ro', isa => 'Str', );
has 'date_in_filename'   => ( is => 'ro', isa => 'Bool', required => 1, default => 1 );
has 'mech'               => ( is => 'ro', isa => 'WWW::Mechanize', lazy_build => 1 );
has 'flvstreamer_binary' => ( is => 'ro', isa => 'Str', required => 1, default => '/usr/bin/flvstreamer', );

# TODO: RCL 2011-09-27 Test for executable binary

has 'cache_time'        => ( is => 'ro', isa => 'Int', required => 1, default => 3600, );
has 'sqlite_cache_size' => ( is => 'ro', isa => 'Int', required => 1, default => 80000, );  # Allow sqlite to use 80MB in memory for caching
has 'cache_dir' => ( is => 'ro', isa => 'Str', required => 1, );

# TODO: RCL 2011-09-27 Test for directory exists

has 'target_dir' => ( is => 'ro', isa => 'Str', required => 1, );

# TODO: RCL 2011-09-27 Test for directory exists

# Some internals - do not need to be in pod documentation
has 'flv'         => ( is => 'ro', isa => 'Video::Flvstreamer', lazy_build => 1 );
has 'cache_files' => ( is => 'ro', isa => 'HashRef',            lazy_build => 1 );
has 'dbh'         => ( is => 'ro', isa => 'DBI::db',            lazy_build => 1 );
has 'file_util'   => (
    is       => 'ro',
    isa      => 'File::Util',
    required => 1,
    lazy     => 1,
    default  => sub { File::Util->new() },
);

# Things to be done after the object has been instanciated
after 'new' => sub {

    # In case a logger hasn't been created elsewhere, this will initialise the default logger
    # for the context
    # It uses init_once so existing configurations won't be clobbered
    my $logger_config = TV::Mediathek::LoggerConfig->new();
    $logger_config->init_logger();
};

# Build the WWW::Mechanize object
sub _build_mech {
    my $self = shift;

    my $mech = WWW::Mechanize->new();
    $mech->proxy( [ 'http', 'ftp' ], $self->proxy ) if ( $self->proxy );
    $mech->agent( $self->agent ) if ( $self->agent );
    $mech->cookie_jar( { file => $self->cookie_jar } ) if ( $self->cookie_jar );
    return $mech;
}

# Build the Video::Flvstreamer object
sub _build_flv {
    my $self = shift;

    # TODO: RCL 2011-09-27 Chang to hash rather than hashref when Flvstreamer updated
    return Video::Flvstreamer->new(
        {
            target_dir  => $self->target_dir,
            timeout     => $self->timeout,
            flvstreamer => $self->flvstreamer_binary,
            socks       => $self->socks,
            debug       => $self->log->is_debug(),
        }
    );

}

# Create a hashref of the paths for the various cache files
sub _build_cache_files {
    my $self = shift;

    my %cache_files = (
        sources   => catfile( $self->cache_dir, 'sources.xml' ),
        media     => catfile( $self->cache_dir, 'media.xml' ),
        media_zip => catfile( $self->cache_dir, 'media.zip' ),
        db        => catfile( $self->cache_dir, 'mediathek.db' ),
    );
    return \%cache_files;
}

# Create the database handle to the SQLite database
sub _build_dbh {
    my $self = shift;

    if ( !-f $self->cache_files->{db} ) {
        $self->init_db();
    }

    my $dbh = DBI->connect( "dbi:SQLite:dbname=" . $self->cache_files->{db}, "", "" );
    if ( !$dbh ) {
        die( "DB could not be initialised: #!" );
    }

    # Make UTF compatible
    $dbh->{sqlite_unicode} = 1;

    # turning synchronous off makes SQLite /much/ faster!
    # It might also be responsible for race conditions where a read doesn't see a write which has just happened...
    $dbh->do( "PRAGMA synchronous=OFF" );
    $dbh->do( "PRAGMA cache_size=" . $self->sqlite_cache_size );
    return $dbh;
}

=head2 refresh_sources

Download the sources into the sources table in the databse.  All current entries are deleted from the
table, and the news entries are added

=cut
sub refresh_sources {
    my $self = shift;

    my $f = File::Util->new();

    # Give some debug info about the cache file
    if ( $self->log->is_debug() && $self->cache_files->{sources} ) {
        $self->log->debug( "Cached sources file " . ( -f $self->cache_files->{sources} ? 'exists' : 'does not exist' ) );
        if ( -f $self->cache_files->{sources} ) {
            $self->log->debug(
                "Cached sources file is " . ( time() - $self->file_util->created( $self->cache_files->{sources} ) ) . 's old' );
        }
    }

    if ( !-f $self->cache_files->{sources}
        || ( time() - $self->file_util->created( $self->cache_files->{sources} ) > $self->cache_time ) )
    {
        $self->log->debug( "Loading sources from internet" );
        $self->get_url_to_file( 'http://zdfmediathk.sourceforge.net/update.xml', $self->cache_files->{sources} );
    }
    $self->log->debug( "Sources XML file is " . Format::Human::Bytes::base10( $self->file_util->size( $self->cache_files->{sources} ) ) );

    $self->log->debug( "Deleting sources table in db" );
    my $sql = 'DELETE FROM sources';
    my $sth = $self->dbh->prepare( $sql );
    $sth->execute;

    # Prepare the Twig handler and graft in the database statement handler for inserting the new values
    my $t = XML::Twig->new( twig_handlers => { Server => \&_source_to_db, }, );
    $sql                = 'INSERT INTO sources ( url, time, tried ) VALUES( ?, ?, 0 )';
    $sth                = $self->dbh->prepare( $sql );
    $t->{mediathek_sth} = $sth;

    $self->log->debug( sprintf "Parsing source XML: %s", $self->cache_files->{sources} );
    $t->parsefile( $self->cache_files->{sources} );
    $self->log->debug( "Finished parsing source XML" );
    $t->purge;
    $sth->finish;
}

# Private XML::Twig twig handler method to parse the source XML file and insert the results
# into the database
sub _source_to_db {
    my ( $t, $section ) = @_;

    my %values;
    ###FIXME - get all children, not just by name
    foreach my $key ( qw/Download_Filme_1 Datum Zeit/ ) {
        my $element = $section->first_child( $key );
        if ( $element ) {
            $values{$key} = $element->text();
        }
    }
    my ( $day,  $month, $year ) = split( /\./, $values{Datum} );
    my ( $hour, $min,   $sec )  = split( /:/,  $values{Zeit} );
    my $date = Class::Date->new( [ $year, $month, $day, $hour, $min, $sec ] );
    $t->{mediathek_sth}->execute( $values{Download_Filme_1}, $date );
}

=head2 refresh_media

Refresh the media listing.
This will try each of the sources from the sources table in the database, ordered by time (youngest first)
and if possible download and import the resulting XML into the database.
Prior to import into the database, all existing data from the channels, themes, media and map_media tables
will be deleted.

=cut
sub refresh_media {
    my ( $self ) = @_;

    $self->refresh_sources();

    # Give some debug info about the cache file
    if ( $self->log->is_debug() && $self->cache_files->{media} ) {
        $self->log->debug(
            sprintf "Cached media file %s %s",
            ( $self->cache_files->{media} ),
            ( -f $self->cache_files->{media} ? 'exists' : 'does not exist' )
        );
        if ( -f $self->cache_files->{media} ) {
            $self->log->debug( sprintf "Cached media file is %us old",
                ( time() - $self->file_util->created( $self->cache_files->{media} ) ) );
        }
    }

    if ( !-f $self->cache_files->{media}
        || ( time() - $self->file_util->created( $self->cache_files->{media} ) > $self->cache_time ) )
    {

        my $sql        = 'SELECT id, url, time FROM sources WHERE tried==0 ORDER BY time DESC LIMIT 1';
        my $sth_select = $self->dbh->prepare( $sql );
        $sql = 'UPDATE sources SET tried=1 WHERE url=?';
        my $sth_update = $self->dbh->prepare( $sql );
        my $got_media  = undef;

        do {
            $sth_select->execute();
            my $row = $sth_select->fetchrow_hashref();

            if ( !$row ) {
                die( "No url found in sources table" );
            }

            $self->log->debug( "Getting media from internet: $row->{url} ($row->{time})" );
            $self->get_url_to_file( $row->{url}, $self->cache_files->{media_zip} );
            $self->log->debug(
                "Compressed file is " . Format::Human::Bytes::base10( $self->file_util->size( $self->cache_files->{media_zip} ) ) );

            $self->log->debug( "Uncompressing media..." );
            my $media_xml;

            # Uncompress the file to an the XML string
            if ( !anyuncompress $self->cache_files->{media_zip} => $self->cache_files->{media} ) {
                $self->log->warn( $AnyUncompressError );
                $sth_update->execute( $row->{url} );

                # next does not work in do/while loop...
            } else {
                $got_media = 1;
            }
        } while ( !$got_media );
        $sth_select->finish();
        $sth_update->finish();
    }
    $self->log->debug( "Media XML file is " . Format::Human::Bytes::base10( $self->file_util->size( $self->cache_files->{media} ) ) );

    $self->log->debug( "Deleting media tables in db" );
    $self->dbh->do( 'DELETE FROM channels' );
    $self->dbh->do( 'DELETE FROM themes' );
    $self->dbh->do( 'DELETE FROM map_media' );
    $self->dbh->do( 'DELETE FROM media' );

    my $t = XML::Twig->new( twig_handlers => { Filme => \&_media_to_db, }, );

    # Prepare the statement handlers
    my $sths = {};
    my $sql =
        'INSERT OR IGNORE INTO media '
      . '( nr, filename, title, date, url, url_auth, url_hd, url_org, url_rtmp, url_theme ) '
      . 'VALUES( ?, ?, ?, ?, ?, ?, ?, ?, ?, ? )';
    $sths->{ins_media} = $self->dbh->prepare( $sql );

    $sql = 'INSERT OR IGNORE INTO channels ( channel ) VALUES( ? )';
    $sths->{ins_channel} = $self->dbh->prepare( $sql );

    $sql = 'INSERT OR IGNORE INTO themes ( channel_id, theme ) VALUES( ?, ? )';
    $sths->{ins_theme} = $self->dbh->prepare( $sql );

    $sql = 'INSERT OR IGNORE INTO map_media ( media_id, theme_id ) VALUES( ?, ? )';
    $sths->{ins_map_media} = $self->dbh->prepare( $sql );

    $sql = 'SELECT id AS channel_id FROM channels WHERE channel=?';
    $sths->{sel_channel_id} = $self->dbh->prepare( $sql );

    $sql = 'SELECT id AS theme_id FROM themes WHERE channel_id=? AND theme=?';
    $sths->{sel_theme_id} = $self->dbh->prepare( $sql );

    $sql = 'SELECT id AS media_id FROM media WHERE url=?';
    $sths->{sel_media_id} = $self->dbh->prepare( $sql );

    $t->{mediathek_sths}          = $sths;
    $t->{mediathek_logger}        = $self->log;
    $t->{mediathek_count_inserts} = 0;

    $self->log->debug( sprintf "Parsing media XML: %s", $self->cache_files->{media} );
    $t->parsefile( $self->cache_files->{media} );
    $self->log->debug( "Finished parsing media XML" );
    $t->purge;

    # Clean up all of the handlers
    foreach ( keys( %$sths ) ) {
        $sths->{$_}->finish;
    }

    $t->{mediathek_sths}          = undef;
    $t->{mediathek_logger}        = undef;
    $t->{mediathek_count_inserts} = undef;

    $self->log->debug( __PACKAGE__ . "->refresh_media end" );
}

# Local XML::Twig twig handler method for importing media to the database.
# Expects to receive a twig with the required statement handlers initialised.
# <Filme><Nr>0000</Nr><Sender>3Sat</Sender><Thema>3sat.full</Thema><Titel>Mediathek-Beiträge</Titel><Datum>04.09.2011</Datum><Zeit>19:23:11</Zeit><Url>http://wstreaming.zdf.de/3sat/veryhigh/110103_jazzbaltica2010ceu_musik.asx</Url><UrlOrg>http://wstreaming.zdf.de/3sat/300/110103_jazzbaltica2010ceu_musik.asx</UrlOrg><Datei>110103_jazzbaltica2010ceu_musik.asx</Datei><Film-alt>false</Film-alt></Filme>
sub _media_to_db {
    my ( $t, $section ) = @_;

    my %values;
    ###FIXME - get all children, not just by name
    foreach my $key ( qw/Datei Nr Sender Thema Titel Datum Url UrlOrg UrlAuth UrlHD UrlRTMP UrlThema/ ) {
        my $element = $section->first_child( $key );
        if ( $element ) {
            $values{$key} = $element->text();
        }
    }

    foreach ( qw/Url Sender Thema Titel/ ) {
        if ( !$values{$_} ) {
            warn( "$_ not defined for entry $values{Nr}.  Skipping.\n" );
            return undef;
        }
    }

    my ( $row, $sql );
    my $sths = $t->{mediathek_sths};
    $sths->{ins_channel}->execute( $values{Sender} );

    $sths->{sel_channel_id}->execute( $values{Sender} );
    $row = $sths->{sel_channel_id}->fetchrow_hashref();
    if ( !$row ) {
        die( "Could not find channel_id for $values{Sender} at entry number $values{Nr}" );
    }
    my $channel_id = $row->{channel_id};

    $sths->{ins_theme}->execute( $channel_id, $values{Thema} );
    $sths->{sel_theme_id}->execute( $channel_id, $values{Thema} );
    $row = $sths->{sel_theme_id}->fetchrow_hashref();
    if ( !$row ) {
        die(    "Could not find themeid for Theme \"$values{Thema}\" and "
              . "Channel \"$values{Sender}\" (channel_id $channel_id) at entry number $values{Nr}" );
    }
    my $theme_id = $row->{theme_id};

    local $Class::Date::DATE_FORMAT = "%Y-%m-%d";
    my $date;
    if ( $values{Datum} ) {
        my ( $day, $month, $year ) = split( /\./, $values{Datum} );
        $date = Class::Date->new( [ $year, $month, $day ] );
    } else {

        #using current time as default
        $date = date( time );
    }

    # Add the media data
    #( filename, title, datum, url, url_auth, url_hd, url_org, url_rtmp, url_theme )
    $sths->{ins_media}->execute(
        $values{Nr},      $values{Datei}, $values{Titel},  $date,            $values{Url},
        $values{UrlAuth}, $values{UrlHD}, $values{UrlOrg}, $values{UrlRTMP}, $values{UrlThema}
    );
    $sths->{sel_media_id}->execute( $values{Url} );
    $row = $sths->{sel_media_id}->fetchrow_hashref();
    if ( !$row ) {
        die( "Could not find media with url $values{Url}" );
    }
    my $media_id = $row->{media_id};

    # And lastly add the mapping
    $sths->{ins_map_media}->execute( $media_id, $theme_id );

    $section->purge;
}

=head2 count_videos

Count the number of videos matching your search criteria.

TODO: RCL 2011-10-28 Documentation

=cut
sub count_videos {
    my ( $self, $args ) = @_;
    my $sql =
        'SELECT COUNT( DISTINCT( m.id ) ) AS count_videos '
      . 'FROM media m '
      . 'JOIN map_media mm ON m.id=mm.media_id '
      . 'JOIN themes t ON t.id=mm.theme_id '
      . 'JOIN channels c ON c.id=t.channel_id';

    my ( @where_sql, @where_args );
    if ( $args->{channel} ) {
        push( @where_sql,  'c.channel=?' );
        push( @where_args, $args->{channel} );
    }
    if ( $args->{theme} ) {
        push( @where_sql,  't.theme=?' );
        push( @where_args, $args->{theme} );
    }
    if ( $args->{title} ) {
        push( @where_sql,  'm.title=?' );
        push( @where_args, $args->{title} );
    }
    if ( $args->{date} ) {
        my $modifier = substr( $args->{date}, 0, 1 );
        my $date = substr( $args->{date}, 1 );
        if ( $modifier =~ m/[<>=]/ ) {
            push( @where_sql,  'm.date' . $modifier . '?' );
            push( @where_args, $date );
        } else {
            $self->log->warn( "Unsupported date modifier: $modifier" );
        }
    }
    if ( scalar( @where_sql ) > 0 ) {
        $sql .= ' WHERE ' . join( ' AND ', @where_sql );
    }

    $self->log->debug( "SQL: $sql" );
    $self->log->debug( "SQL Args: " . join( ', ', @where_args ) );
    my $sth = $self->dbh->prepare( $sql );
    $sth->execute( @where_args );
    my $row = $sth->fetchrow_hashref();
    return $row->{count_videos};
}

=head2 list

List the videos matching your search criteria.

TODO: RCL 2011-10-28 Document search options

=cut
sub list {
    my ( $self, $args ) = @_;

    my ( @joins, @selects, @where_sql, @where_args );
    push( @selects, 'c.channel' );
    push( @selects, 'c.id AS channel_id' );
    if ( $args->{channel} ) {
        if ( $args->{channel} =~ m/\*/ ) {
            $args->{channel} =~ s/\*/\%/g;
            push( @where_sql, 'c.channel LIKE ?' );
        } else {
            push( @where_sql, 'c.channel=?' );
        }
        push( @where_args, $args->{channel} );
    }
    if ( $args->{list_all} || $args->{channel} || $args->{theme} || $args->{title} || $args->{media_id} ) {
        push( @joins,   'JOIN themes t ON c.id=t.channel_id' );
        push( @selects, 't.theme' );
        push( @selects, 't.id AS theme_id' );
    }
    if ( $args->{theme} ) {
        if ( $args->{theme} =~ m/\*/ ) {
            $args->{theme} =~ s/\*/\%/g;
            push( @where_sql, 't.theme LIKE ?' );
        } else {
            push( @where_sql, 't.theme=?' );
        }
        push( @where_args, $args->{theme} );
    }
    if ( $args->{list_all} || $args->{title} || $args->{theme} || $args->{media_id} ) {
        push( @selects, 'm.id AS media_id' );
        push( @selects, 'm.*' );
        push( @joins,   'JOIN map_media mm ON mm.theme_id=t.id' );
        push( @joins,   'JOIN media m ON mm.media_id=m.id' );
    }
    if ( $args->{title} ) {
        if ( $args->{title} =~ m/\*/ ) {
            $args->{title} =~ s/\*/\%/g;
            push( @where_sql, 'm.title LIKE ?' );
        } else {
            push( @where_sql, 'm.title=?' );
        }
        push( @where_args, $args->{title} );
    }
    if ( $args->{media_id} ) {
        push( @where_sql,  'm.id=?' );
        push( @where_args, $args->{media_id} );
    }
    if ( $args->{date} ) {
        my $modifier = substr( $args->{date}, 0, 1 );
        my $date = substr( $args->{date}, 1 );
        if ( $modifier =~ m/[<>=]/ ) {
            push( @where_sql,  'm.date' . $modifier . '?' );
            push( @where_args, $date );
        } else {
            $self->log->warn( "Unsupported date modifier: $modifier" );
        }
    }

    my $sql = 'SELECT ' . join( ', ', @selects ) . ' FROM channels c ' . join( ' ', @joins );
    if ( scalar( @where_sql ) > 0 ) {
        $sql .= ' WHERE ' . join( ' AND ', @where_sql );
    }

    $self->log->debug( "SQL: $sql" );
    $self->log->debug( "SQL Args: " . join( ', ', @where_args ) );

    my $sth = $self->dbh->prepare( $sql );
    $sth->execute( @where_args );
    my $row;
    my $out;
    while ( $row = $sth->fetchrow_hashref() ) {
        $out->{channels}->{ $row->{channel_id} } = $row->{channel};
        if ( $row->{theme_id} ) {
            $out->{themes}->{ $row->{theme_id} } = {
                theme      => $row->{theme},
                channel_id => $row->{channel_id}
            };
        }
        if ( $row->{media_id} ) {
            $out->{media}->{ $row->{media_id} } = {
                title    => $row->{title},
                date     => $row->{date},
                theme_id => $row->{theme_id},
                url      => $row->{url}
            };
        }
    }
    return $out;
}

=head2 get_videos

Download (to the target_dir) the videos matching your search criteria.

TODO: RCL 2011-10-28 Document search options

=cut
sub get_videos {
    my ( $self, $args ) = @_;

    $args->{list_all} = 1;
    my $list = $self->list( $args );

    # TODO: RCL 2011-11-04 -1 is not a safe or intuitively understood value for "no abo"
    my $abo_id = $args->{abo_id} || -1;

    if ( !$list->{media} ) {
        $self->log->warn( "No videos found matching your search..." );
    }

    $self->log->info( "Found " . scalar( keys( %{ $list->{media} } ) ) . " videos to download" );

    my $sth = $self->dbh->prepare( 'INSERT INTO downloads ( abo_id, media_id, path, url, time ) ' . 'VALUES( ?, ?, ?, ?, ? )' );

    foreach my $media_id ( sort( keys( %{ $list->{media} } ) ) ) {
        my $video      = $list->{media}->{$media_id};
        my $theme      = to_ascii( $list->{themes}->{ $video->{theme_id} }->{theme} );
        my $channel    = to_ascii( $list->{channels}->{ $list->{themes}->{ $video->{theme_id} }->{channel_id} } );
        my $date       = $list->{media}->{$media_id}->{date};
        my $target_dir = catfile( $self->target_dir, $channel, $theme );
        $target_dir =~ s/\s/_/g;
        $self->log->debug( "Target dir: $target_dir" );
        if ( !-d $target_dir ) {
            if ( !$self->file_util->make_dir( $target_dir ) ) {
                die( "Could not make target dir: $target_dir" );
            }
        }
        my $title = to_ascii( $video->{title} );

        #TODO: find a module which replaces all bad-in-filename characters
        $title =~ s/\(/_/g;
        $title =~ s/\)/_/g;
        $title =~ s/\//_/g;
        $title =~ s/\W/_/g;
        if( $self->date_in_filename ){ 
            $title = sprintf( '%s_%s', $date, $title );
        }
        
        my $target_path = catfile( $target_dir, $title . '.avi' );
        # TODO: RCL 2011-11-04 If this is an abo, check if it has already been downloaded downloaded         
        if ( $self->requires_download( { path => $target_path } ) && !$args->{test} ) {
            $self->log->info(
                sprintf( "Getting %s%s || %s || %s", ( $args->{test} ? '>>TEST<< ' : '' ), $channel, $theme, $video->{title} ) );
            if ( $video->{url} =~ /^http/ ) {
                my @args = ( "/usr/bin/mplayer", "-playlist", to_ascii( $video->{url} ), "-dumpstream", "-dumpfile", $target_path );
                $self->log->debug( sprintf( "Running: %s", "@args" ) );
                system( @args ) == 0 or $self->log->warn( sprintf( "%s", $! ) );
            } else {

                # Sometimes the url is not just a url, it's a whole load of arguments tailored for a flvstreamer
                # download.
                # e.g. --host vod.daserste.de --app ardfs/ --playpath mp4:videoportal/mediathek/W+wie+Wissen/c_150000/156934/format168877.f4v --resume -q -o /tmp/mediathek_target/ARD/W_wie_Wissen/Erblindung_durch_Parasiten_Infektion.avi
                # These have to be passed as individual arguments, otherwise flvstreamer will receive the whole
                # string as one argument and will not be able to parse it.
                my @video_args = split( ' ', $video->{url} );
                $self->flv->get_raw( \@video_args, $target_path );
            }

            if ( -e $target_path ) {
                if ( !defined $sth->execute( $abo_id, $media_id, $target_path, $video->{url}, date( time ) ) ) {
                    $self->log->error( "Could not insert downloaded media: $DBI::errstr" );
                }
            } else {
                $self->log->warn( sprintf( "Could not download %s", $video->{title} ) );
            }
        }
    }
    $sth->finish();
}

=head2 add_abo

TODO: RCL 2012-01-26 Document

=cut
sub add_abo {
    my ( $self, $args ) = @_;

    if ( !$args->{channel} && !$args->{theme} && !$args->{title} ) {
        $self->log->warn( "Abo would download all media. Please specify a filter.\n" );
        return undef;
    }

    my $sth = $self->dbh->prepare( 'INSERT INTO abos ( name, channel, theme, ' . 'title, expires_after) VALUES( ?, ?, ?, ?, ? )' );
    if ( $sth->execute( $args->{name}, $args->{channel}, $args->{theme}, $args->{title}, $args->{expires} ) ) {
        $self->log->info( "Abo \"$args->{name}\" successfully added." );
    } else {
        $self->log->error( "Abo not added: $DBI::errstr" );
    }
    $sth->finish();
}

=head2 del_abo

TODO: RCL 2012-01-26 Documentation

=cut
sub del_abo {
    my ( $self, $args ) = @_;

    my $result = $self->dbh->do( "DELETE FROM abos WHERE name='$args->{name}'" );
    if ( $result == 1 ) {
        $self->log->info( "Abo \"$args->{name}\" successfully deleted." );
    } elsif ( $result == 0 ) {
        $self->log->warn( "Abo \"$args->{name}\" not found." );
    } elsif ( !defined $result ) {
        $self->log->error( "Abo not deleted: $DBI::errstr" );
    }
}

=head2 get_abos

TODO: RCL 2012-01-26 Documentation

=cut
sub get_abos {
    my ( $self ) = @_;

    my $arr_ref = $self->dbh->selectall_arrayref( "SELECT name FROM abos ORDER BY name" );
    if ( !defined $arr_ref ) {
        $self->log->error( "An error occurred while retrieving abos: $DBI::errstr" );
        return ();
    }

    return @{$arr_ref};
}

=head2 run_abo

TODO: RCL 2012-01-26 Documentation

=cut
sub run_abo {
    my ( $self, $args ) = @_;

    my $arr_ref = $self->dbh->selectall_arrayref( "SELECT * FROM abos WHERE name='$args->{name}'", { Slice => {} } );
    if ( !defined $arr_ref ) {
        $self->log->error( "An error occurred while retrieving abo \"$args->{name}\": $DBI::errstr" );
    } elsif ( @{$arr_ref} == 0 ) {
        $self->log->warn( "Abo \"$args->{name}\" not found." );
    } else {
        my $abo = @{$arr_ref}[0];
        if ( $abo->{expires_after} > 0 ) {
            $self->log->debug( "Abo \"$abo->{name}\" has expiry date. Checking expired downloads..." );
            $self->expire_downloads( { abo_id => $abo->{abo_id}, expires_after => $abo->{expires_after} } );
        }
        $self->log->debug( "Abo \"$abo->{name}\" has no expiry date. Proceeding with downloads..." );
        $self->get_videos(
            {
                channel => $abo->{channel},
                theme   => $abo->{theme},
                title   => $abo->{title},
                abo_id  => $abo->{abo_id}
            }
        );
    }
}

=head2 get_downloaded_media

TODO: RCL 2012-01-26 Documentation

=cut
sub get_downloaded_media {
    my ( $self ) = @_;

    my $sql =
        "SELECT abos.name, downloads.media_id, downloads.path, downloads.time "
      . "FROM downloads LEFT OUTER JOIN abos ON abos.abo_id=downloads.abo_id WHERE "
      . "downloads.expired=0 ORDER BY downloads.time";

    my $arr_ref = $self->dbh->selectall_arrayref( $sql, { Slice => {} } );
    if ( !defined $arr_ref ) {
        $self->log->error( "An error occurred while retrieving media: $DBI::errstr" );
        return ();
    }

    return @{$arr_ref};
}

=head2 del_downloaded

TODO: RCL 2012-01-26 Documentation

=cut
sub del_downloaded {
    my ( $self, $args ) = @_;

    my $arr_ref = $self->dbh->selectall_arrayref( "SELECT path FROM downloads WHERE " . "media_id=$args->{id}", { Slice => {} } );
    if ( !defined $arr_ref ) {
        $self->log->error( "An error occurred while retrieving media: $DBI::errstr" );
    } elsif ( @{$arr_ref} > 1 ) {
        $self->log->error( "Database inconsistency: media refers to several downloads." );
    } elsif ( @{$arr_ref} == 0 ) {
        $self->log->warn( "Media not found." );
    } else {
        my $file = ${$arr_ref}[0]->{path};
        if ( unlink $file ) {
            if ( defined $self->dbh->do( "DELETE FROM downloads WHERE media_id=$args->{id}" ) ) {
                $self->log->info( "Media \"$file\" successfully deleted." );
            } else {
                $self->log->error( "Media \"$file\" deleted, but not removed from database: $DBI::errstr" );
            }
        } else {
            $self->log->error( "Could not delete file: $file" );
        }
    }
}

=head2 expire_downloads

TODO: RCL 2012-01-26 Documentation

=cut
sub expire_downloads {
    my ( $self, $args ) = @_;

    my $arr_ref =
      $self->dbh->selectall_arrayref( "SELECT * FROM downloads WHERE " . "abo_id=$args->{abo_id} AND expired=0 ", { Slice => {} } );
    if ( !defined $arr_ref ) {
        $self->log->error( "Could not retrieve expired downloads: $DBI::errstr" );
    } elsif ( @{$arr_ref} > 0 ) {
        foreach my $download ( @$arr_ref ) {
            my $now        = date( time );
            my $exp        = "$args->{expires_after}D";
            my $expires_on = date( $download->{time} ) + $exp;
            if ( $now > $expires_on ) {
                if ( unlink $download->{path} ) {
                    if ( defined $self->dbh->do( "UPDATE downloads SET expired=1 WHERE path='$download->{path}'" ) ) {
                        $self->log->info( "$download->{path} expired on $expires_on. Deleted." );
                    } else {
                        $self->log->error( "Media \"$download->{path}\" deleted, but not removed from database: $DBI::errstr" );
                    }
                } else {
                    $self->log->error( "Could not delete file: $download->{path}" );
                }
            } else {
                $self->log->debug( "$download->{path} expires on $expires_on. Not deleting." );
            }
        }
    } else {
        $self->log->debug( "All downloads already expired." );
    }
}

=head2 requires_download

TODO: RCL 2012-01-26 Documentation

=cut
sub requires_download {
    my ( $self, $args ) = @_;

    if ( -e $args->{path} ) {
        $self->log->info( "Media already downloaded: $args->{path}" );
        return 0;
    }

    my $arr_ref = $self->dbh->selectall_arrayref( "SELECT expired FROM downloads WHERE " . "path='$args->{path}'" );
    if ( defined $arr_ref ) {
        if ( @{$arr_ref} == 0 ) {
            return 1;
        }

        my $expired = @{$arr_ref}[0];
        if ( @{$expired}[0] == 1 ) {
            $self->log->info( "Media $args->{path} expired. Not downloading." );
            return 0;
        }
    } else {
        $self->log->error( "Could not identify required downloads: $DBI::errstr" );
    }

    return 1;
}

=head2 get_url_to_file

TODO: RCL 2012-01-26 Documentation

=cut
sub get_url_to_file {
    my ( $self, $url, $filename ) = @_;
    $self->log->debug( "Saving $url to $filename" );
    my $response = $self->mech->get( $url );
    if ( !$response->is_success ) {
        die( "get failed: " . $response->status_line . "\n" );
    }

    my $write_mode = '>';
    my $binmode    = 1;
    if ( $filename =~ m/\.xml$/ ) {
        $write_mode .= ':encoding(UTF-8)';
        $binmode = undef;
    }

    if ( !open( FH, $write_mode, $filename ) ) {
        die( "Could not open file: $filename\n$!\n" );
    }
    if ( $binmode ) {
        binmode( FH );
    }
    print FH $response->decoded_content;
    close FH;
}

=head2 init_db

TODO: RCL 2012-01-26 Documentation

=cut
sub init_db {
    my ( $self ) = @_;
    $self->log->debug( sprintf "got cache file for db: %s\n", $self->cache_files->{db} );

    if ( -f $self->cache_files->{db} ) {
        $self->log->debug( "Deleting old database" );
        unlink( $self->cache_files->{db} );
    }
    my $dbh = DBI->connect( "dbi:SQLite:dbname=" . $self->cache_files->{db}, "", "" );
    if ( !$dbh ) {
        die( "Could not connect to DB during init_db: $!" );
    }
    $self->log->debug( "Reading SQL file in" );

    require 'TV/Mediathek/CreateDB.pm';
    my $sql_generator = TV::Mediathek::CreateDB->new( dbh => $dbh );
    my $sql = $sql_generator->create_sql;

    my @commands = split( /;/, $sql );
    foreach ( @commands ) {
        $self->log->debug( "SQL: $_\n" );
        $dbh->do( $_ );
    }
    $dbh->disconnect;
}

=head1 AUTHOR

Robin Clarke, C<< <perl at robinclarke.net> >>

=head1 BUGS

Please report any bugs or feature requests to L<https://github.com/robin13/mediathekp>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc TV::Mediathek


You can also look for information at:

=over 4

=item * Github

L<https://github.com/robin13/mediathekp>

=item * Search CPAN

L<http://search.cpan.org/dist/TV/Mediathek/>

=back


=head1 ACKNOWLEDGEMENTS

Thanks to Michael Unterkalmsteiner for added functionality!

=head1 LICENSE AND COPYRIGHT

Copyright 2011 Robin Clarke.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1;
