use Test::More;

use CPAN::Mini::Inject;
use lib 't/lib';

BEGIN {
  eval "use CPANServer";

  plan skip_all => "HTTP::Server::Simple required to test update_mirror"
   if $@;
  plan tests => 3;
}

my $server = CPANServer->new( 11027 );
my $pid    = $server->background;
ok( $pid, 'HTTP Server started' );
# Give server time to get going.
sleep 1;

$SIG{__DIE__} = sub { kill( 9, $pid ) };

my $mcpi = CPAN::Mini::Inject->new;
$mcpi->loadcfg( 't/.mcpani/config' )->parsecfg;

$mcpi->testremote;
is( $mcpi->{site}, 'http://localhost:11027/', 'Correct remote URL' );

$mcpi->loadcfg( 't/.mcpani/config_badremote' )->parsecfg;

$mcpi->testremote;
is( $mcpi->{site}, 'http://localhost:11027/',
  'Selects correct remote URL' );

kill( 9, $pid );

unlink( 't/testconfig' );
