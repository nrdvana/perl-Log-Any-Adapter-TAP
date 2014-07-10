#! /usr/bin/env perl

use strict;
use warnings;
use Test::More;
use Log::Any;

$SIG{__DIE__}= $SIG{__WARN__}= sub { diag @_; };

$ENV{TAP_LOG_FILTER}= 'warn,Foo=trace,Bar=debug';
use_ok( 'Log::Any::Adapter', 'TAP' ) || BAIL_OUT;

my $buf;

sub test_log_method {
	my ($category, $method, $message, $stdout_pattern, $stderr_pattern)= @_;
	my ($stdout, $stderr)= ('', '');
	{
		local *STDOUT;
		local *STDERR;
		open STDOUT, '>', \$stdout or die "Can't redirect stdout to a memory buffer: $!";
		open STDERR, '>', \$stderr or die "Can't redirect stderr to a memory buffer: $!";
		Log::Any->get_logger(category => $category)->$method($message);
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

test_log_method( @$_ ) for (
	[ 'main', 'error', 'test-main-err',  '', "# error: test-main-err\n" ],
	[ 'main', 'warn',  'test-main-warn', '', '' ],
	[ 'Foo',  'debug', 'test-foo-debug', "# debug: test-foo-debug\n", '' ],
	[ 'Foo',  'trace', 'test-foo-trace', '', '' ],
	[ 'Bar',  'info',  'test-bar-info',  "# test-bar-info\n", '' ],
	[ 'Bar',  'debug', 'test-bar-debug', '', '' ],
);

done_testing;