package Log::Any::Adapter::TAP;
use strict;
use warnings;
use parent 'Log::Any::Adapter::Filtered';
use Try::Tiny;
use Carp 'croak';
require Scalar::Util;
require Data::Dumper;

our $VERSION= '0.002000';

# ABSTRACT: Logging adapter suitable for use in TAP testcases

=head1 DESCRIPTION

When running testcases, you probably want to see some of your logging
output.  One sensible approach is to have all C<warn> and more serious
messages emitted as C<diag> output on STDERR, and less serious messages
emitted as C<note> comments on STDOUT.

So, thats what this logging adapter does.  Simply say

  use Log::Any::Adapter 'TAP';

at the start of your testcase, and now you have your logging output as
part of your TAP stream.

By default, C<debug> and C<trace> are suppressed, but you can enable
them with L</TAP_LOG_FILTER> or the L</filter> attribute.  See below.

=head1 ENVIRONMENT

=head2 TAP_LOG_FILTER

Specify the default filter value.  See attribute L</filter> for details.

You may also specify defaults per-category, using this syntax:

  $default_level,$package_1=$level,...,$package_n=$level

So, for example:

  TAP_LOG_FILTER=trace,MyPackage=none,NoisyPackage=warn prove -lv

=head2 TAP_LOG_ORIGIN

Set this variable to 1 to show which category the message came from,
or 2 to see the file and line number it came from, or 3 to see both.

=head2 TAP_LOG_SHOW_USAGE

Defaults to true, which prints a TAP comment briefing the user about
these environment variables when Log::Any::Adapter::TAP is first loaded.

Set TAP_LOG_SHOW_USAGE=0 to suppress this message.

=cut

our $show_category;
our $show_file_line;
our $show_file_fullname;
our $show_usage;

BEGIN {
	my $class= __PACKAGE__;
	# Apply TAP_LOG_FILTER settings
	if ($ENV{TAP_LOG_FILTER}) {
		for (split /,/, $ENV{TAP_LOG_FILTER}) {
			if (index($_, '=') > -1) {
				my ($pkg, $level)= split /=/, $_;
				local $@;
				eval { $class->_coerce_filter_level($level); $class->set_default_filter_for($pkg => $level); 1; }
					or warn "$@";
			}
			else {
				local $@;
				eval { $class->_coerce_filter_level($_); $class->set_default_filter_for('' => $_); 1; }
					or warn "$@";
			}
		}
	}
	
	# Apply TAP_LOG_ORIGIN
	if ($ENV{TAP_LOG_ORIGIN}) {
		$show_category= $ENV{TAP_LOG_ORIGIN} & 1;
		$show_file_line= $ENV{TAP_LOG_ORIGIN} & 2;
		$show_file_fullname= $show_file_line;
	}
	
	# Will show usage on first instance created, but suppress if ENV var
	# is defined and false.
	$show_usage= 1 unless defined $ENV{TAP_LOG_SHOW_USAGE} && !$ENV{TAP_LOG_SHOW_USAGE};
}

=head1 ATTRIBUTES

=head2 filter

  use Log::Any::Adapter 'TAP', filter => 'info';
  use Log::Any::Adapter 'TAP', filter => 'debug+3';

Messages with a log level equal to or less than the filter are suppressed.

Defaults to L</TAP_LOG_FILTER>, or C<debug> which
suppresses C<debug> and C<trace> messages.

Filter may be:

=over

=item *

Any of the log level names or level aliases defined in L<Log::Any>.

=item *

C<none> or C<undef>, to filter nothing (print all log levels).

=item *

A value of C<all>, to filter everything (print nothing).

=back

The filter level may end with a C<+N> or C<-N> indicating an offset from
the named level.  The numeric values increase with importance of the message,
so C<debug-1> is equivalent to C<trace> and C<debug+1> is equivalent to C<info>.
This differs from syslog, where increasing numbers are less important.
(why did they choose that??)

=head2 dumper

  use Log::Any::Adapter 'TAP', dumper => sub { my $val=shift; ... };

Use a custom dumper function for converting perl data to strings.
The dumper is only used for the C<${level}f(...)> formatting functions,
and for log levels C<debug> and C<trace>.
All other logging will stringify the object in the normal way.

Defaults to L</default_dumper>, which prints the data in "some human-readable
format".  The default will NOT give you a pure serialization, and is subject
to change.

=head1 METHODS

=head2 new

See L<Log::Any::Adapter::Base/new>.  Accepts the above attributes.

=cut

sub init {
	my $self= shift;
	$self->SUPER::init(@_);
	
	# As a courtesy to people running "prove -v", we show a quick usage for env
	# vars that affect logging output.  This can be suppressed by either
	# filtering the 'info' level, or setting env var TAP_LOG_SHOW_USAGE=0
	if ($show_usage) {
		$self->info("Logging via ".ref($self)."; set TAP_LOG_FILTER=none to see"
		           ." all log levels, and TAP_LOG_ORIGIN=3 to see caller info.");
		$show_usage= 0;
	}
	
	return $self;
}

=head2 write_msg

  $self->write_msg( $level_name, $message_string )

This is an internal method which all the other logging methods call.  You can
override it if you want to create a derived logger that handles line wrapping
differently, or write to different file handles.

=cut

my %_tap_method;
sub write_msg {
	my ($self, $level_name, $str)= @_;
	
	chomp $str;
	$str= "$level_name: $str" unless $level_name eq 'info';
	
	if ($show_category) {
		$str .= ' (' . $self->category . ')';
	}
	
	if ($show_file_line) {
		my $i= 0;
		++$i while caller($i) =~ /^Log::Any(:|$)/;
		my (undef, $file, $line)= caller($i);
		$file =~ s|.*/lib/||
			unless $show_file_fullname;
		$str .= ' (' . $file . ':' . $line . ')';
	}

	# Was going to cache more of this, but logger might load before Test::More,
	# so better to keep testing it each time.  At least cache which method name we're using.
	my $name= ($_tap_method{$level_name} ||= ($self->_log_level_value($level_name) >= $self->_log_level_value('warning')? 'diag':'note'));
	my $m;
	if ($m= main->can($name)) {
		$m->($str);
	}
	elsif (Test::Builder->can('new')) {
		Test::Builder->new->$name($str);
	}
	else {
		$str =~ s/\n/\n#   /sg;
		if ($name eq 'diag') {
			print STDERR "# $str\n";
		} else {
			print STDOUT "# $str\n";
		}
	}
}

=head2 default_dumper

  $dumper= $class->default_dumper;
  $string = $dumper->( $perl_data );

Default value for the 'dumper' attribute.

This returns a coderef which can dump a value in "some human readable format".
Currently it uses Data::Dumper with a max depth of 4.
Do not depend on this default; it is only for human consumption, and might
change to a more friendly format in the future.

=head1 LOGGING METHODS

This module has all the standard logging methods from L<Log::Any/LOG LEVELS>.

For regular logging functions (i.e. C<warn>, C<info>) the arguments are
stringified and concatenated.  Errors during stringify or printing are not
caught.

For printf-like logging functions (i.e. C<warnf>, C<infof>) reference
arguments are passed to C<$self-E<gt>dumper> before passing them to
sprintf.  Errors are not caught here either.

For any log level below C<info>, errors ARE caught with an C<eval> and printed
as a warning.
This is to prevent sloppy debugging code from ever crashing a production system.
Also, references are passed to C<$self-E<gt>dumper> even for the regular methods.

=cut

1;