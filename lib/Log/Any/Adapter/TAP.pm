package Log::Any::Adapter::TAP;
use strict;
use warnings;
use parent 'Log::Any::Adapter::Base';
use Try::Tiny;
use Carp 'croak';
require Scalar::Util;
require Data::Dumper;

our $VERSION= '0.001000';

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
them with C<TAP_LOG_FILTER>.  See below.

=head1 ENV{TAP_LOG_FILTER}

Specify the lowest log level which should be suppressed.  The default is
C<debug>, which suppresses C<debug> and C<trace> messages.
A value of "none" enables all logging levels.

If you want to affect specific logging categories use a notation like

  TAP_LOG_FILTER=trace,MyPackage=none,NoisyPackage=warn prove -lv

The filter level may end with a "+N" or "-N" indicating an offset from
the named level, so C<debug-1> is equivalent to C<trace> and C<debug+1>
is equivalent to C<info>.

=head1 ENV{TAP_LOG_ORIGIN}

Set this variable to 1 to show which category the message came from,
or 2 to see the file and line number it came from, or 3 to see both.

=cut

our $global_filter_level;
our $show_category;
our $show_file_line;
our $show_file_fullname;
our %category_filter_level;
our %level_map;

=head1 ATTRIBUTES

=head2 filter

  use Log::Any::Adapter 'TAP', filter => 'info';
  use Log::Any::Adapter 'TAP', filter => 'debug+3';

Messages equal to or less than the level of filter are suppressed.

The default filter is 'debug', meaning C<debug> and C<trace> are suppressed.

filter may be:

=over 5

=item *

a level name like 'info', 'debug', etc, or a level alias as documented
in Log::Any.

=item *

undef, or the string 'none', which do not suppress anything

=item *

a level name with a numeric offset, where a number will be added or
subtracted from the log level.  Larger numbers are for more important
levels, so C<debug+1> is equivalent to C<info>

=back

=cut

sub filter { $_[0]{filter} }

=head2 dumper

  use Log::Any::Adapter 'TAP', dumper => sub { my $val=shift; ... };

Use a custom dumper function for converting perl data to strings.
The dumper is only used for the "*f()" formatting functions, and for log
levels 'debug' and 'trace'.  All normal logging will stringify the object
in the normal way.

=cut

sub dumper { $_[0]{dumper} || \&_default_dumper }

sub category { $_[0]{category} }

=head1 METHODS

=head2 new

See L<Log::Any::Adapter::Base/new>.  Accepts the above attributes.

=cut

sub init {
	my $self= shift;
	$self->{filter}= exists $self->{filter}? _coerce_filter_level($self->{filter})
		: defined $category_filter_level{$self->{category}}? $category_filter_level{$self->{category}}
		: $global_filter_level;
	# Rebless to a "level filter" package, which is a subclass of this one
	# but with some methods replaced by empty subs.
	# If log level is negative (trace), we show all messages, so no need to rebless.
	bless $self, ref($self).'::Lev'.($self->{filter}+1)
		if $self->{filter} >= -1;
}

=head2 write_msg

  $self->write_msg( $level_name, $message_string )

This is an internal method which all the other logging methods call.  You can
override it if you want to create a derived logger that handles line wrapping
differently, or write to different file handles.

=cut

sub write_msg {
	my ($self, $level_name, $str)= @_;
	chomp $str;
	$str =~ s/\n/\n#   /sg;
	if ($show_category) {
		$str .= ' (' . $self->category . ')';
	}
	if ($show_file_line) {
		my $i= 0;
		++$i while caller($i) =~ '^Log::Any';
		my (undef, $file, $line)= caller($i);
		$file =~ s|.*/lib/||
			unless $show_file_fullname;
		$str .= ' (' . $file . ':' . $line . ')';
	}
	if ($level_map{$level_name} >= $level_map{warning}) {
		print STDERR ($level_name eq 'info'? '# ' : "# $level_name: "), $str, "\n";
	} else {
		print STDOUT ($level_name eq 'info'? '# ' : "# $level_name: "), $str, "\n";
	}
}

=head2 _default_dumper

  $string = _default_dumper( $perl_data );

This is a function which dumps a value in a human readable format.  Currently
it uses Data::Dumper with a max depth of 4, but might change in the future.

This is the default value for the 'dumper' attribute.

=cut

sub _default_dumper {
	my $val= shift;
	try {
		Data::Dumper->new([$val])->Indent(0)->Terse(1)->Useqq(1)->Quotekeys(0)->Maxdepth(4)->Sortkeys(1)->Dump;
	} catch {
		my $x= "$_";
		$x =~ s/\n//;
		substr($x, 50)= '...' if length $x >= 50;
		"<exception $x>";
	};
}

sub _coerce_filter_level {
	my $val= shift;
	return (!defined $val || $val eq 'none')? $level_map{trace}-1
		: exists $level_map{$val}? $level_map{$val}
		: ($val =~ /^([A-Za-z]+)[-+]([0-9]+)$/) && defined $level_map{lc $1}? $level_map{lc $1} - $2
		: croak "unknown log level '$val'";
}

BEGIN {
	$global_filter_level= 0;
	%level_map= (
		trace    => -1,
		debug    =>  0,
		info     =>  1,
		notice   =>  2,
		warning  =>  3,
		error    =>  4,
		critical =>  5,
		fatal    =>  5,
	);

	# create filter-level packages
	# this is an optimization for minimal overhead of disabled log levels
	for (0..5) {
		no strict 'refs';
		push @{__PACKAGE__ . "::Lev${_}::ISA"}, __PACKAGE__;
	}
	
	my $prev_level= 0;
	# We implement the stock methods, but also 'fatal' because in my mind, fatal is not
	# an alias for 'critical' and I want to see a prefix of "fatal" on messages.
	my %seen;
	foreach my $method ( grep { !$seen{$_}++ } Log::Any->logging_methods(), 'fatal' ) {
		my $level= $level_map{$method};
		if (defined $level) {
			$prev_level= $level;
		} else {
			# If we get an unexpected method name, assume same numeric level as previous.
			# I'm attempting to be future-proof, here.
			$level= $prev_level;
			$level_map{$method}= $prev_level;
		}
		my $impl= ($method ne 'debug' && $method ne 'trace')
			# Standard logging
			? sub {
				(shift)->write_msg($method, join('', map { !defined $_? '<undef>' : $_ } @_));
			}
			# Debug and trace logging
			: sub {
				my $self= shift;
				eval { $self->write_msg($method, join('', map { !defined $_? '<undef>' : !ref $_? $_ : $self->dumper->($_) } @_)); };
			};
		my $printfn=
			sub {
				my $self= shift;
				$self->write_msg($method, sprintf((shift), map { !defined $_? '<undef>' : !ref $_? $_ : $self->dumper->($_) } @_));
			};

		# Install methods in base package
		no strict 'refs';
		*{__PACKAGE__ . "::$method"}= $impl;
		*{__PACKAGE__ . "::${method}f"}= $printfn;
		*{__PACKAGE__ . "::is_$method"}= sub { 1 };
		
		# Suppress methods in all higher filtering level packages
		foreach ($level+1 .. 5) {
			*{__PACKAGE__ . "::Lev${_}::$method"}= sub {};
			*{__PACKAGE__ . "::Lev${_}::${method}f"}= sub {};
			*{__PACKAGE__ . "::Lev${_}::is_$method"}= sub { 0 }
		}
	}

	# Now create any alias that isn't handled
	my %aliases= Log::Any->log_level_aliases;
	for my $method (grep { !$seen{$_}++ } keys %aliases) {
		my $level= $level_map{$method};
		$level= $level_map{$method}= $level_map{$aliases{$method}}
			unless defined $level;

		# Install methods in base package
		no strict 'refs';
		*{__PACKAGE__ . "::$method"}=    *{__PACKAGE__ . "::$aliases{$method}"};
		*{__PACKAGE__ . "::${method}f"}= *{__PACKAGE__ . "::$aliases{$method}f"};
		*{__PACKAGE__ . "::is_$method"}= *{__PACKAGE__ . "::is_$aliases{$method}"};

		# Suppress methods in all higher filtering level packages
		foreach ($level+1 .. 5) {
			*{__PACKAGE__ . "::Lev${_}::$method"}= sub {};
			*{__PACKAGE__ . "::Lev${_}::${method}f"}= sub {};
			*{__PACKAGE__ . "::Lev${_}::is_$method"}= sub { 0 }
		}
	}
	
	# Apply TAP_LOG_FILTER settings
	if ($ENV{TAP_LOG_FILTER}) {
		for (split /,/, $ENV{TAP_LOG_FILTER}) {
			if (index($_, '=') > -1) {
				my ($pkg, $level)= split /=/, $_;
				$category_filter_level{$pkg}= &_coerce_filter_level($level);
			}
			else {
				$global_filter_level= &_coerce_filter_level($_);
			}
		}
	}
	
	# Apply TAP_LOG_ORIGIN
	if ($ENV{TAP_LOG_ORIGIN}) {
		$show_category= $ENV{TAP_LOG_ORIGIN} & 1;
		$show_file_line= $ENV{TAP_LOG_ORIGIN} & 2;
		$show_file_fullname= $show_file_line;
	}
}

1;