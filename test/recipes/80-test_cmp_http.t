#! /usr/bin/env perl
# Copyright 2007-2021 The OpenSSL Project Authors. All Rights Reserved.
# Copyright Nokia 2007-2019
# Copyright Siemens AG 2015-2019
#
# Licensed under the Apache License 2.0 (the "License").  You may not use
# this file except in compliance with the License.  You can obtain a copy
# in the file LICENSE in the source distribution or at
# https://www.openssl.org/source/license.html

use strict;
use warnings;

use POSIX;
use OpenSSL::Test qw/:DEFAULT with data_file data_dir srctop_dir bldtop_dir result_dir/;
use OpenSSL::Test::Utils;

BEGIN {
    setup("test_cmp_http");
}
use lib srctop_dir('Configurations');
use lib bldtop_dir('.');

plan skip_all => "These tests are not supported in a fuzz build"
    if config('options') =~ /-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION/;

plan skip_all => "These tests are not supported in a no-cmp build"
    if disabled("cmp");
plan skip_all => "These tests are not supported in a no-ec build"
    if disabled("ec");

plan skip_all => "Tests involving local HTTP server not available on Windows, AIX or VMS"
    if $^O =~ /^(VMS|MSWin32|AIX)$/;
plan skip_all => "Tests involving local HTTP server not available in cross-compile builds"
    if defined $ENV{EXE_SHELL};
plan skip_all => "Tests involving local HTTP server require 'kill' command"
    if system("which kill >/dev/null");
plan skip_all => "Tests involving local HTTP server require 'lsof' command"
    if system("which lsof >/dev/null"); # this typically excludes Solaris

sub chop_dblquot { # chop any leading and trailing '"' (needed for Windows)
    my $str = shift;
    $str =~ s/^\"(.*?)\"$/$1/;
    return $str;
}

my $proxy = "<EMPTY>";
$proxy = chop_dblquot($ENV{http_proxy} // $ENV{HTTP_PROXY} // $proxy);
$proxy =~ s{^https?://}{}i;
my $no_proxy = $ENV{no_proxy} // $ENV{NO_PROXY};

my $app = "apps/openssl cmp";

# the CMP server configuration consists of:
my $ca_dn;      # The CA's Distinguished Name
my $server_dn;  # The server's Distinguished Name
my $server_host;# The server's host name or IP address
my $server_port;# The server's port
my $server_tls; # The server's TLS port, if any, or 0
my $server_path;# The server's CMP alias
my $server_cert;# The server's cert
my $kur_port;   # The server's port for kur (cert update)
my $pbm_port;   # The server port to be used for PBM
my $pbm_ref;    # The reference for PBM
my $pbm_secret; # The secret for PBM
my $column;     # The column number of the expected result
my $sleep = 0;  # The time to sleep between two requests

# The local $server_name variables below are among others taken as the name of a
# sub-directory with server-specific certs etc. and CA-specific config section.

sub load_config {
    my $server_name = shift;
    my $section = shift;
    my $test_config = $ENV{OPENSSL_CMP_CONFIG} // "$server_name/test.cnf";
    open (CH, $test_config) or die "Cannot open $test_config: $!";
    my $active = 0;
    while (<CH>) {
        if (m/\[\s*$section\s*\]/) {
            $active = 1;
        } elsif (m/\[\s*.*?\s*\]/) {
            $active = 0;
        } elsif ($active) {
            $ca_dn       = $1 eq "" ? '""""' : $1 if m/^\s*ca_dn\s*=\s*(.*)?\s*$/;
            $server_dn   = $1 eq "" ? '""""' : $1 if m/^\s*server_dn\s*=\s*(.*)?\s*$/;
            $server_host = $1 eq "" ? '""""' : $1 if m/^\s*server_host\s*=\s*(\S*)?\s*(\#.*)?$/;
            $server_port = $1 eq "" ? '""""' : $1 if m/^\s*server_port\s*=\s*(.*)?\s*$/;
            $server_tls  = $1 eq "" ? '""""' : $1 if m/^\s*server_tls\s*=\s*(.*)?\s*$/;
            $server_path = $1 eq "" ? '""""' : $1 if m/^\s*server_path\s*=\s*(.*)?\s*$/;
            $server_cert = $1 eq "" ? '""""' : $1 if m/^\s*server_cert\s*=\s*(.*)?\s*$/;
            $kur_port    = $1 eq "" ? '""""' : $1 if m/^\s*kur_port\s*=\s*(.*)?\s*$/;
            $pbm_port    = $1 eq "" ? '""""' : $1 if m/^\s*pbm_port\s*=\s*(.*)?\s*$/;
            $pbm_ref     = $1 eq "" ? '""""' : $1 if m/^\s*pbm_ref\s*=\s*(.*)?\s*$/;
            $pbm_secret  = $1 eq "" ? '""""' : $1 if m/^\s*pbm_secret\s*=\s*(.*)?\s*$/;
            $column      = $1 eq "" ? '""""' : $1 if m/^\s*column\s*=\s*(.*)?\s*$/;
            $sleep       = $1 eq "" ? '""""' : $1 if m/^\s*sleep\s*=\s*(.*)?\s*$/;
        }
    }
    close CH;
    die "Cannot find all CMP server config values in $test_config section [$section]\n"
        if !defined $ca_dn
        || !defined $server_dn || !defined $server_host
        || !defined $server_port || !defined $server_tls
        || !defined $server_path || !defined $server_cert
        || !defined $kur_port || !defined $pbm_port
        || !defined $pbm_ref || !defined $pbm_secret
        || !defined $column || !defined $sleep;
    $server_dn = $server_dn // $ca_dn;
}

my @server_configurations = ("Mock");
@server_configurations = split /\s+/, $ENV{OPENSSL_CMP_SERVER} if $ENV{OPENSSL_CMP_SERVER};
# set env variable, e.g., OPENSSL_CMP_SERVER="Mock Insta" to include further CMP servers

my @all_aspects = ("connection", "verification", "credentials", "commands", "enrollment");
@all_aspects = split /\s+/, $ENV{OPENSSL_CMP_ASPECTS} if $ENV{OPENSSL_CMP_ASPECTS};
# set env variable, e.g., OPENSSL_CMP_ASPECTS="commands enrollment" to select specific aspects

my $faillog;
my $file = $ENV{HARNESS_FAILLOG}; # pathname relative to result_dir
if ($file) {
    open($faillog, ">", $file) or die "Cannot open $file for writing: $!";
}

sub test_cmp_http {
    my $server_name = shift;
    my $aspect = shift;
    my $n = shift;
    my $i = shift;
    my $title = shift;
    my $params = shift;
    my $expected_exit = shift;
    my $path_app = bldtop_dir($app);
    with({ exit_checker => sub {
        my $actual_exit = shift;
        my $OK = $actual_exit == $expected_exit;
        if ($faillog && !$OK) {
            my $quote_spc_empty = sub { $_ eq "" ? '""' : $_ =~ m/ / ? '"'.$_.'"' : $_ };
            my $invocation = "$path_app ".join(' ', map $quote_spc_empty->($_), @$params);
            print $faillog "$server_name $aspect \"$title\" ($i/$n)".
                " expected=$expected_exit actual=$actual_exit\n";
            print $faillog "$invocation\n\n";
        }
        return $OK; } },
         sub { ok(run(cmd([$path_app, @$params,])),
                  $title); });
}

sub test_cmp_http_aspect {
    my $server_name = shift;
    my $aspect = shift;
    my $tests = shift;
    subtest "CMP app CLI $server_name $aspect\n" => sub {
        my $n = scalar @$tests;
        plan tests => $n;
        my $i = 1;
        foreach (@$tests) {
            test_cmp_http($server_name, $aspect, $n, $i++, $$_[0], $$_[1], $$_[2]);
            sleep($sleep);
        }
    };
    # not unlinking test.certout*.pem, test.cacerts.pem, and test.extracerts.pem
}

# The input files for the tests done here dynamically depend on the test server
# selected (where the Mock server used by default is just one possibility).
# On the other hand the main test configuration file test.cnf, which references
# several server-dependent input files by relative file names, is static.
# Moreover the tests use much greater variety of input files than output files.
# Therefore we chose the current directory as a subdirectory of $SRCTOP and it
# was simpler to prepend the output file names by BLDTOP than doing the tests
# from $BLDTOP/test-runs/test_cmp_http and prepending the input files by SRCTOP.

indir data_dir() => sub {
    plan tests => @server_configurations * @all_aspects
        + (grep(/^Mock$/, @server_configurations)
           && grep(/^certstatus$/, @all_aspects));

    foreach my $server_name (@server_configurations) {
        $server_name = chop_dblquot($server_name);
        load_config($server_name, $server_name);
        {
          SKIP: {
            my $pid;
            if ($server_name eq "Mock") {
                indir "Mock" => sub {
                    $pid = start_mock_server("");
                    skip "Cannot start or find the started CMP mock server",
                        scalar @all_aspects unless $pid;
                }
            }
            foreach my $aspect (@all_aspects) {
                $aspect = chop_dblquot($aspect);
                next if $server_name eq "Mock" && $aspect eq "certstatus";
                load_config($server_name, $aspect); # update with any aspect-specific settings
                indir $server_name => sub {
                    my $tests = load_tests($server_name, $aspect);
                    test_cmp_http_aspect($server_name, $aspect, $tests);
                };
            };
            stop_mock_server($pid) if $pid;
          }
        }
    };
};

close($faillog) if $faillog;

sub load_tests {
    my $server_name = shift;
    my $aspect = shift;
    my $test_config = $ENV{OPENSSL_CMP_CONFIG} // "$server_name/test.cnf";
    my $file = data_file("test_$aspect.csv");
    my $result_dir = result_dir();
    my @result;

    open(my $data, '<', $file) || die "Cannot open $file for reading: $!";
  LOOP:
    while (my $line = <$data>) {
        chomp $line;
        $line =~ s{\r\n}{\n}g; # adjust line endings
        $line =~ s{_CA_DN}{$ca_dn}g;
        $line =~ s{_SERVER_DN}{$server_dn}g;
        $line =~ s{_SERVER_HOST}{$server_host}g;
        $line =~ s{_SERVER_PORT}{$server_port}g;
        $line =~ s{_SERVER_TLS}{$server_tls}g;
        $line =~ s{_SERVER_PATH}{$server_path}g;
        $line =~ s{_SERVER_CERT}{$server_cert}g;
        $line =~ s{_KUR_PORT}{$kur_port}g;
        $line =~ s{_PBM_PORT}{$pbm_port}g;
        $line =~ s{_PBM_REF}{$pbm_ref}g;
        $line =~ s{_PBM_SECRET}{$pbm_secret}g;
        $line =~ s{_RESULT_DIR}{$result_dir}g;

        next LOOP if $server_tls == 0 && $line =~ m/,\s*-tls_used\s*,/;
        my $noproxy = $no_proxy;
        if ($line =~ m/,\s*-no_proxy\s*,(.*?)(,|$)/) {
            $noproxy = $1;
        } elsif ($server_host eq "127.0.0.1") {
            # do connections to localhost (e.g., Mock server) without proxy
            $line =~ s{-section,,}{-section,,-no_proxy,127.0.0.1,} ;
        }
        if ($line =~ m/,\s*-proxy\s*,/) {
            next LOOP if $no_proxy && ($noproxy =~ $server_host);
        } else {
            $line =~ s{-section,,}{-section,,-proxy,$proxy,};
        }
        $line =~ s{-section,,}{-section,,-certout,$result_dir/test.cert.pem,};
        $line =~ s{-section,,}{-config,../$test_config,-section,$server_name $aspect,};

        my @fields = grep /\S/, split ",", $line;
        s/^<EMPTY>$// for (@fields); # used for proxy=""
        s/^\s+// for (@fields); # remove leading whitespace from elements
        s/\s+$// for (@fields); # remove trailing whitespace from elements
        s/^\"(\".*?\")\"$/$1/ for (@fields); # remove escaping from quotation marks from elements
        my $expected_exit = $fields[$column];
        my $description = 1;
        my $title = $fields[$description];
        next LOOP if (!defined($expected_exit)
                      || ($expected_exit ne 0 && $expected_exit ne 1));
        @fields = grep {$_ ne 'BLANK'} @fields[$description + 1 .. @fields - 1];
        push @result, [$title, \@fields, $expected_exit];
    }
    close($data);
    return \@result;
}

sub mock_server_pid {
    return `lsof -iTCP:$server_port` =~ m/\n\S+\s+(\d+)\s+[^\n]+LISTEN/s ? $1 : 0;
}

sub start_mock_server {
    my $args = $_[0]; # optional further CLI arguments
    my $dir = bldtop_dir("");
    my $cmd = "LD_LIBRARY_PATH=$dir DYLD_LIBRARY_PATH=$dir " .
        bldtop_dir($app) . " -config server.cnf $args";
    my $pid = mock_server_pid();
    if ($pid) {
        print "Mock server already running with pid=$pid\n";
        return $pid;
    }
    print "Current directory is ".getcwd()."\n";
    print "Launching mock server listening on port $server_port: $cmd\n";
    return system("$cmd &") == 0 # start in background, check for success
        ? (sleep 1, mock_server_pid()) : 0;
}

sub stop_mock_server {
    my $pid = $_[0];
    print "Killing mock server with pid=$pid\n";
    system("kill $pid") if $pid;
}