#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'TV::Mediathek' ) || print "Bail out!\n";
}

diag( "TV::Mediathek $TV::Mediathek::VERSION, Perl $], $^X" );
