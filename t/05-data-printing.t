#! /usr/bin/perl

use strict;
use warnings;
use Test::More;
use Log::Any '$log';
use FindBin;
use lib "$FindBin::Bin/lib";
use TestLogging;

$SIG{__DIE__}= $SIG{__WARN__}= sub { diag @_; };

use_ok( 'Log::Any::Adapter', 'TAP', filter => 'none' ) or die;

my $buf;

test_log_method($log, @$_) for (
	# method, message, pattern
	[ 'fatal',   { foo => 42 },   '', qr/HASH/    ],
	[ 'error',   [ 1, 2, 3 ],     '', qr/ARRAY/   ],
	[ 'debug',   { foo => 42 },   qr/foo.*42/, '' ],
	[ 'trace',   [ 1, 2, 3 ],     qr/1.*2.*3/, '' ],
);

done_testing;
