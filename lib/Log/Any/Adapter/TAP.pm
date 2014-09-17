package Log::Any::Adapter::TAP;
use strict;
use warnings;
use parent 'Log::Any::Adapter::Base';
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
them with C<TAP_LOG_FILTER>.  See below.

=head1 ENVIRONMENT

=head2 ENV{TAP_LOG_FILTER}

Specify the lowest log level which should be suppressed.  The default is
C<debug>, which suppresses C<debug> and C<trace> messages.
A value of "none" enables all logging levels.

If you want to affect specific logging categories use a notation like

  TAP_LOG_FILTER=trace,MyPackage=none,NoisyPackage=warn prove -lv

The filter level may end with a "+N" or "-N" indicating an offset from
the named level, so C<debug-1> is equivalent to C<trace> and C<debug+1>
is equivalent to C<info>.

=head2 ENV{TAP_LOG_ORIGIN}

Set this variable to 1 to show which category the message came from,
or 2 to see the file and line number it came from, or 3 to see both.

=head2 ENV{TAP_LOG_SHOW_USAGE}

Defaults to true, which prints a #note on stdout describing these
environment variables when Log::Any::Adapter::TAP is first loaded.

Set TAP_LOG_SHOW_USAGE=0 to suppress this message.

=cut

our $global_filter_level;    # default for level-filtering
our %category_filter_level;  # per-category filter levels
our $show_category;          # whether to show logging category on each message
our $show_file_line;         # Whether to show caller for each message
our $show_file_fullname;     # whether to use full path for caller info
our $show_usage;             # whether to print usage notes on initialization
our %level_map;              # mapping from level name to numeric level

sub _coerce_filter_level {
	my $val= shift;
	return (!defined $val || $val eq 'none')? $level_map{trace}-1
		: ($val eq 'all')? $level_map{emergency}
		: exists $level_map{$val}? $level_map{$val}
		: ($val =~ /^([A-Za-z]+)([-+][0-9]+)$/) && defined $level_map{lc $1}? $level_map{lc $1} + $2
		: croak "unknown log level '$val'";
}

BEGIN {
	# Initialize globals, and use %ENV vars for defaults
	%level_map= (
		trace     => -1,
		debug     =>  0,
		info      =>  1,
		notice    =>  2,
		warning   =>  3,
		error     =>  4,
		critical  =>  5,
		alert     =>  6,
		emergency =>  7,
	);
	
	# Make sure we have numeric levels for all the core logging methods
	for ( Log::Any->logging_methods() ) {
		if (!defined $level_map{$_}) {
			# This is an attempt at being future-proof to the degree that a new level
			# added to Log::Any won't kill a program using this logging adapter,
			# but will emit a warning so it can be fixed properly.
			warn __PACKAGE__." encountered unknown level '$_'";
			$level_map{$_}= 4;
		}
	}
	# Now add numeric values for all the aliases, too
	my %aliases= Log::Any->log_level_aliases;
	$level_map{$_} ||= $level_map{$aliases{$_}}
		for keys %aliases;
	
	# Suppress debug and trace by default
	$global_filter_level= $level_map{debug};
	
	# Apply TAP_LOG_FILTER settings
	if ($ENV{TAP_LOG_FILTER}) {
		for (split /,/, $ENV{TAP_LOG_FILTER}) {
			if (index($_, '=') > -1) {
				my ($pkg, $level)= split /=/, $_;
				eval { $category_filter_level{$pkg}= _coerce_filter_level($level); 1; }
					or warn "$@";
			}
			else {
				eval { $global_filter_level= _coerce_filter_level($_); 1; }
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
	my $level= exists $self->{filter}? _coerce_filter_level($self->{filter})
		: defined $category_filter_level{$self->{category}}? $category_filter_level{$self->{category}}
		: $global_filter_level;
	$level= $level_map{emergency} if $level > $level_map{emergency};
	# Rebless to a "level filter" package, which is a subclass of this one
	# but with some methods replaced by empty subs.
	# If log level is negative (trace), we show all messages, so no need to rebless.
	my $pkg_id= $level+1;
	bless $self, ref($self)."::Lev$pkg_id"
		if $pkg_id >= 0;
	
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

# Programmatically generate all the info, infof, is_info ... methods
sub _build_logging_methods {
	my $class= shift;
	my %seen;
	# We implement the stock methods, but also 'fatal' because in my mind, fatal is not
	# an alias for 'critical' and I want to see a prefix of "fatal" on messages.
	for my $method ( grep { !$seen{$_}++ } Log::Any->logging_methods(), 'fatal' ) {
		my $impl= ($level_map{$method} >= $level_map{info})
			# Standard logging.  Concatenate everything as a string.
			? sub {
				(shift)->write_msg($method, join('', map { !defined $_? '<undef>' : $_ } @_));
			}
			# Debug and trace logging.  For these, we trap exceptions and dump data structures
			: sub {
				my $self= shift;
				local $@;
				eval { $self->write_msg($method, join('', map { !defined $_? '<undef>' : !ref $_? $_ : $self->dumper->($_) } @_)); };
			};
		my $printfn=
			# Formatted logging.  We dump data structures (because Log::Any says to)
			sub {
				my $self= shift;
				$self->write_msg($method, sprintf((shift), map { !defined $_? '<undef>' : !ref $_? $_ : $self->dumper->($_) } @_));
			};
		
		# Install methods in base package
		no strict 'refs';
		*{"${class}::$method"}= $impl;
		*{"${class}::${method}f"}= $printfn;
		*{"${class}::is_$method"}= sub { 1 };
	}
	# Now create any alias that isn't handled
	my %aliases= Log::Any->log_level_aliases;
	for my $method (grep { !$seen{$_}++ } keys %aliases) {
		no strict 'refs';
		*{"${class}::$method"}=    *{"${class}::$aliases{$method}"};
		*{"${class}::${method}f"}= *{"${class}::$aliases{$method}f"};
		*{"${class}::is_$method"}= *{"${class}::is_$aliases{$method}"};
	}
}

# Create per-filter-level packages
# This is an optimization for minimizing overhead when using disabled levels
sub _build_filtered_subclasses {
	my $class= shift;
	my $max_level= 0;
	$_ > $max_level and $max_level= $_
		for values %level_map;
	
	# Create packages, inheriting from $class
	for (0..$max_level+1) {
		no strict 'refs';
		push @{"${class}::Lev${_}::ISA"}, $class;
	}
	# For each method, mask it in any package of a higher filtering level
	for my $method (keys %level_map) {
		my $level= $level_map{$method};
		# Suppress methods in all higher filtering level packages
		for ($level+1 .. $max_level+1) {
			no strict 'refs';
			*{"${class}::Lev${_}::$method"}= sub {};
			*{"${class}::Lev${_}::${method}f"}= sub {};
			*{"${class}::Lev${_}::is_$method"}= sub { 0 }
		}
	}
}

BEGIN {
	__PACKAGE__->_build_logging_methods;
	__PACKAGE__->_build_filtered_subclasses;
}

1;