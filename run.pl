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

my $Port = {
  http => 5255,
  https => 5256,
};

my $Browser = $ENV{TEST_WD_BROWSER} || 'chromium';

my $wd = Promised::Docker::WebDriver->$Browser;
my $p = promised_cleanup {
  return $wd->stop;
} $wd->start->then (sub {
  my $prefix = $wd->get_url_prefix;
  my $con = Web::Driver::Client::Connection->new_from_url
      (Web::URL->parse_string ($prefix));
  my $host = $wd->get_docker_host_hostname_for_container;
  my $exit;
  return promised_cleanup {
    return $con->close;
  } promised_for {
    return if $exit;
    my $path = shift;
    return promised_for {
      my $proto = shift;
      my $name = $path->relative ($TestDataPath);
      warn "$name ($proto)...\n";

      my $cmd = Promised::Command->new ([
        $HttpPath->child ('perl'),
        $HttpPath->child ('t_deps/bserver.pl'),
      ]);
      $cmd->envs->{SERVER_PORT} = $Port->{http};
      $cmd->envs->{SERVER_TLS_PORT} = $Port->{https};
      $cmd->envs->{TEST_METHOD} = quotemeta $name;
      if ($ENV{DEBUG} and $ENV{TEST_METHOD}) {
        $cmd->envs->{TEST_METHOD} = $ENV{TEST_METHOD};
      }
      my $cmd_err = '';
      $cmd->stderr (sub {
        $cmd_err .= $_[0] if defined $_[0];
      });
      $cmd->timeout (60*3);
      my $session;
      return promised_cleanup {
        return $session->close if defined $session;
      } Promise->all ([
        $cmd->run,
        $con->new_session (required => {
          acceptInsecureCerts => \1,
        }),
      ])->then (sub {
        $session = $_[0]->[1];
        return promised_wait_until {
          return $cmd_err =~ /^Listening.+:$Port->{http}/m;
        } timeout => 60;
      })->then (sub {
        my $server_url = Web::URL->parse_string
            ($proto . qq<://$host:> . $Port->{$proto});
        #warn "Server <@{[$server_url->stringify]}> is ready\n";
        return $session->go ($server_url);
      })->then (sub {
        return $cmd->wait;
      })->then (sub {
        die $_[0] unless $_[0]->exit_code == 0;
      })->then (sub {
        return $session->execute (q{
          return [
            document.documentElement.outerHTML,
            document.querySelectorAll ("tbody tr.PASS").length,
            document.querySelectorAll ("tbody tr:not(.PASS)").length,
          ];
        });
      })->then (sub {
        my $res = $_[0];
        my $status = ($res->json->{value}->[1] > 0 &&
                      $res->json->{value}->[2] == 0) ? 'PASS' : 'FAIL';
        my $result_path = $OutPath->child ($Browser, $status, $proto, $name . '.html');
        my $result_file = Promised::File->new_from_path ($result_path);
        return $result_file->write_char_string ($res->json->{value}->[0]);
      }, sub {
        my $e = $_[0];
        my $result2_path = $OutPath->child
            ($Browser, 'FAIL', $proto, $name . '-error.txt');
        my $result2_file = Promised::File->new_from_path ($result2_path);
        return $result2_file->write_char_string (join "\n", $cmd_err, $e)->then (sub {
          return $session->execute (q{
            return document.documentElement.outerHTML;
          }) if defined $session;
          return undef;
        })->then (sub {
          my $res = $_[0];
          return unless defined $res;
          my $result_path = $OutPath->child
              ($Browser, 'FAIL', $proto, $name . '.html');
          my $result_file = Promised::File->new_from_path ($result_path);
          return $result_file->write_char_string ($res->json->{value});
        })->catch (sub {
          warn $_[0];
        });
      })->then (sub {
        $exit = 1 if $ENV{DEBUG};
      });
    } ['https', 'http']; # $proto
  } [(sort { $a cmp $b } $TestDataPath->children (qr/\.dat$/))];
});
$p->to_cv->recv;

## License: Public Domain.
