#! /usr/bin/perl

use strict;
use warnings;
use Test::More;
use Log::Any '$log';

$SIG{__DIE__}= $SIG{__WARN__}= sub { diag @_; };

use_ok( 'Log::Any::Adapter', 'TAP', filter => 'none' ) or die;

my $buf;

sub test_log_method {
	my ($method, $message, $stdout_pattern, $stderr_pattern)= @_;
	my ($stdout, $stderr)= ('', '');
	{
		local *STDOUT;
		local *STDERR;
		open STDOUT, '>', \$stdout or die "Can't redirect stdout to a memory buffer: $!";
		open STDERR, '>', \$stderr or die "Can't redirect stderr to a memory buffer: $!";
		$log->$method($message);
		close STDOUT;
		close STDERR;
	}
	if (ref $stdout_pattern) {
		like( $stdout, $stdout_pattern, "result of $method($message) stdout" );
	} else {
		is( $stdout, $stdout_pattern, "result of $method($message) stdout" );
	}
	if (ref $stderr_pattern) {
		like( $stderr, $stderr_pattern, "result of $method($message) stderr" );
	} else {
		is( $stderr, $stderr_pattern, "result of $method($message) stderr" );
	}
}

my @tests= (
	# method, message, pattern
	[ 'fatal',   { foo => 42 },   '', qr/HASH/    ],
	[ 'error',   [ 1, 2, 3 ],     '', qr/ARRAY/   ],
	[ 'debug',   { foo => 42 },   qr/foo.*42/, '' ],
	[ 'trace',   [ 1, 2, 3 ],     qr/1.*2.*3/, '' ],
);
test_log_method(@$_) for @tests;

done_testing;
