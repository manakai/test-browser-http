use strict;
use warnings;
use Path::Tiny;
use Promised::Flow;
use Promised::File;
use Promised::Command;
use Web::URL;
use Web::Driver::Client::Connection;
use Promised::Docker::WebDriver;

my $RootPath = path (__FILE__)->parent;
my $HttpPath = $RootPath->child ('modules/web-resource');
my $TestDataPath = $HttpPath->child ('t_deps/data');

my $OutPath = defined $ENV{CIRCLE_ARTIFACTS}
    ? path ($ENV{CIRCLE_ARTIFACTS}) : $RootPath->child ('local/artifacts');

my $HttpPort = 5255;
my $HttpsPort = 5256;

my $Browser = $ENV{TEST_WD_BROWSER} || 'chromium';

my $wd = Promised::Docker::WebDriver->$Browser;
my $p = promised_cleanup {
  return $wd->stop;
} $wd->start->then (sub {
  my $prefix = $wd->get_url_prefix;
  my $session = Web::Driver::Client::Connection->new_from_url
      (Web::URL->parse_string ($prefix));
  my $host = $wd->get_docker_host_hostname_for_container;
  return promised_cleanup {
    return $session->close;
  } promised_for {
    my $path = shift;
    my $name = $path->relative ($TestDataPath);

    my $cmd = Promised::Command->new ([
      $HttpPath->child ('perl'),
      $HttpPath->child ('t_deps/bserver.pl'),
    ]);
    $cmd->envs->{SERVER_PORT} = $HttpPort;
    $cmd->envs->{SERVER_TLS_PORT} = $HttpsPort;
    $cmd->envs->{TEST_METHOD} = quotemeta $name;
    return $cmd->run->then (sub {
      return $cmd->wait;
    })->then (sub {
      return $session->go (Web::URL->parse_string (qq<http://$host:$HttpPort>));
    })->then (sub {
# XXXXX
# XXX wait
# XXX timeout
      return $session->execute (q{
        return document.documentElement.outerHTML;
      });
    })->then (sub {
      my $res = $_[0];
      my $result_path = $OutPath->child ($Browser, $name . '.html');
      my $result_file = Promised::File->new_from_path ($result_path);
      return $result_file->write_char_string ($res->json->{value});
    });
  } ($TestDataPath->children (qr/\.dat$/));
});
$p->to_cv->recv;

## License: Public Domain.
