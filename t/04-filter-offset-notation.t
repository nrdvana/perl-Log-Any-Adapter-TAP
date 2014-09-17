#! /usr/bin/perl

use strict;
use warnings;
use Test::More;
use Log::Any '$log';

$SIG{__DIE__}= $SIG{__WARN__}= sub { diag @_; };

use_ok( 'Log::Any::Adapter', 'TAP' ) or die;

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

note "filter level 'info-1'";
Log::Any::Adapter->set('TAP', filter => 'info-1');

my @tests= (
	# method, message, pattern
	[ 'fatal',   'test-fatal',   '', "# fatal: test-fatal\n" ],
	[ 'error',   'test-error',   '', "# error: test-error\n" ],
	[ 'warning', 'test-warning', '', "# warning: test-warning\n" ],
	[ 'notice',  'test-notice',  "# notice: test-notice\n", '' ],
	[ 'info',    'test-info',    "# test-info\n", '' ],
	[ 'debug',   'test-debug',   '', '' ],
	[ 'trace',   'test-trace',   '', '' ],
);
test_log_method(@$_) for @tests;

note "filter level 'info+1'";
Log::Any::Adapter->set('TAP', filter => 'info+1');

@tests= (
	# method, message, pattern
	[ 'fatal',   'test-fatal',   '', "# fatal: test-fatal\n" ],
	[ 'error',   'test-error',   '', "# error: test-error\n" ],
	[ 'warning', 'test-warning', '', "# warning: test-warning\n" ],
	[ 'notice',  'test-notice',  '', '' ],
	[ 'info',    'test-info',    '', '' ],
	[ 'debug',   'test-debug',   '', '' ],
	[ 'trace',   'test-trace',   '', '' ],
);
test_log_method(@$_) for @tests;

done_testing;
