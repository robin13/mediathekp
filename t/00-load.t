#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Video::DE::Mediathek' ) || print "Bail out!\n";
}

diag( "Testing Video::DE::Mediathek $Video::DE::Mediathek::VERSION, Perl $], $^X" );
