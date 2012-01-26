package TV::Mediathek::CreateDB;
use Moose;
=head1 NAME

TV::Mediathek::CreateDB - Create the SQLite DB for storing media data

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

  my $create_db = TV::Mediathek::CreateDB();
  my $sql = $create_db->create_sql();

=cut

has 'dbh' => (
    is       => 'ro',
    isa      => 'DBI::db',
    required => 1,
);

has 'create_sql' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    builder => '_build_create_sql'
);

sub _build_create_sql {
    my $self  = shift;
    my @lines = <DATA>;

    my $sql = '';
  LINE:
    foreach my $line ( @lines ) {
        if ( $line =~ m/^\s*$/ || $line =~ m/^\-\-/ || $line =~ m/^\#/ ) {
            next LINE;
        }
        chomp( $line );
        $sql .= $line;
    }
    return $sql;
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

DROP TABLE IF EXISTS dbstate;
CREATE TABLE dbstate(
    id INTEGER PRIMARY KEY,
    state_key TEXT,
    state_val TEXT
);
CREATE INDEX state_val_index ON dbstate (state_key);

DROP TABLE IF EXISTS media;
CREATE TABLE media(
    `id` INTEGER PRIMARY KEY,
    `nr` INTEGER,
    `filename` TEXT,
    `title` TEXT,
    `date` DATE,
    `url` TEXT UNIQUE NOT NULL,
    `url_auth` TEXT,
    `url_hd` TEXT,
    `url_org` TEXT,
    `url_rtmp` TEXT,
    `url_theme` TEXT
    );
CREATE INDEX media_title_index ON media ( title );
CREATE INDEX media_nr_index ON media ( nr );
CREATE INDEX media_url_org_index ON media ( url_org );
CREATE INDEX media_url_index ON media ( url );
CREATE INDEX media_time_index ON media ( time );

DROP TABLE IF EXISTS channels;
CREATE TABLE channels(
    `id` INTEGER PRIMARY KEY,
    `channel` TEXT UNIQUE NOT NULL
);
CREATE INDEX channels_channel_index ON channels( channel );

DROP TABLE IF EXISTS themes;
CREATE TABLE themes(
    `id` INTEGER PRIMARY KEY,
    `channel_id` INTEGER NOT NULL,
    `theme` TEXT
);
CREATE UNIQUE INDEX themes_unique_index ON themes ( channel_id, theme );
CREATE INDEX themes_theme_index ON themes( theme );
CREATE INDEX themes_channel_index ON themes( channel_id );

DROP TABLE IF EXISTS map_media;
CREATE TABLE map_media(
    `id` INTEGER PRIMARY KEY,
    `media_id` INTEGER NOT NULL,    
    `theme_id` INTEGER NOT NULL
);
CREATE INDEX map_media_mediaid_index ON map_media( media_id );
CREATE INDEX map_media_themeid_index ON map_media( theme_id );

DROP TABLE IF EXISTS downloads;
CREATE TABLE downloads(
    `abo_id` INTEGER,
    `media_id` INTEGER NOT NULL,
    `path` TEXT UNIQUE NOT NULL,
    `url` TEXT UNIQUE NOT NULL,
    `time` DATETIME NOT NULL,
    `expired` BINARY DEFAULT 0
);
CREATE INDEX downloads_abo_id_index ON downloads( abo_id );
CREATE INDEX downloads_path_index ON downloads( path );

DROP TABLE IF EXISTS abos;
CREATE TABLE abos(
    `abo_id` INTEGER PRIMARY KEY,
    `name` TEXT UNIQUE NOT NULL,
    `channel` TEXT,
    `theme` TEXT,
    `title` TEXT,
    `expires_after` INTEGER DEFAULT 0
);
CREATE INDEX abos_name_index ON abos( name );

DROP TABLE IF EXISTS sources;
CREATE TABLE sources(
    `id` INTEGER PRIMARY KEY,
    `time` DATETIME,
    `url` TEXT,
    `tried` BINARY DEFAULT 0
    );
CREATE INDEX sources_time_index ON sources ( time );
CREATE INDEX sources_tried_index ON sources ( tried );

