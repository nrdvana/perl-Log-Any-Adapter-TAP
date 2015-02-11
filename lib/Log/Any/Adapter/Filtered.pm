package Log::Any::Adapter::Filtered;
use strict;
use warnings;
use parent 'Log::Any::Adapter::Base';
use Carp 'croak';
require Scalar::Util;
require Data::Dumper;

our $VERSION= '0.001000';

# ABSTRACT: Logging adapter base class with support for filtering

=head1 DESCRIPTION

The most important feature I saw lacking from Log::Any::Adapter::Stdout was
the ability to easily filter out unwanted log levels on a per-category basis.

This logging base class addresses that missing feature, providing some
structure for other adapter classes to quickly implement filtering in an
efficient way.

This package gives you:

=over

=item *

A class attribute for mapping numeric values to log levels

=item *

A read/write class attribute to define default filters, per-category,
which also inherits the defaults from base classes.

=item *

Compile-time helper method to build one subclass for each log level
with the appropriate level-methods squelched.  i.e. a subclass called
YOUR_CLASS::Filter0 which defines C<sub debug {}> to suppress calls
to filtered levels with minimal overhead.

=item *

Compile-time helper method to build logger methods that all call
the method C<write_msg($level_name, $msg_string)> which you must
then define.

=back

=head1 NUMERIC LOG LEVELS

In order to filter "this level and below" there must be a concept of numeric
log leveels.  We get these form the method _log_level_value, and a default
implementation simply assigns increasing values to each level, with 'info'
having a value of 1 (which I think is easy to remember).

=head2 _log_level_value

  my $n= $class->_log_level_value('info');

Takes one argument of a log level name or alias name, and returns a numeric
value for it.  Increasing numbers indicate higher priority.

This method also accepts the values 'min' and 'max', to return the lowest
and highest numeric value that can occur.  This is used for things like
C<filter => 'all'> and C<filter => 'none'>.

=cut

our %level_map;              # mapping from level name to numeric level
BEGIN {
	# Initialize globals, and use %ENV vars for defaults
	%level_map= (
		min       => -1,
		trace     => -1,
		debug     =>  0,
		info      =>  1,
		notice    =>  2,
		warning   =>  3,
		error     =>  4,
		critical  =>  5,
		alert     =>  6,
		emergency =>  7,
		max       =>  7,
	);
	# Make sure we have numeric levels for all the core logging methods
	for ( Log::Any->logging_methods() ) {
		if (!defined $level_map{$_}) {
			# This is an attempt at being future-proof to the degree that a new level
			# added to Log::Any won't kill a program using this logging adapter,
			# but will emit a warning so it can be fixed properly.
			warn __PACKAGE__." encountered unknown log level '$_'";
			$level_map{$_}= 4;
		}
	}
	# Now add numeric values for all the aliases, too
	my %aliases= Log::Any->log_level_aliases;
	$level_map{$_} ||= $level_map{$aliases{$_}}
		for keys %aliases;
}

sub _log_level_value { $level_map{$_[1]} }

=head1 FILTERS

A filter can be specified for a specific logger instance, or come from a
default.  This package provides both an accessor for the filter of an
instance and class-accessors for the defaults.

=head2 filter

  use Log::Any::Adapter 'Filtered', filter => 'info';
  print $log->filter;

Filter is an attribute of the generated logger.

=cut

sub filter { $_[0]{filter} }

=head2 _coerce_filter_level

  my $log_level= $class->_coerce_filter_level( 'info' );
  my $log_level= $class->_coerce_filter_level( 'info+2' );
  my $log_level= $class->_coerce_filter_level( 'info-1' );
  my $log_level= $class->_coerce_filter_level( 'all' );
  my $log_level= $class->_coerce_filter_level( 'none' );

Take a symbolic specification for a log level and return its log_level number.

=cut

sub _coerce_filter_level {
	my ($class, $val)= @_;
	my $n;
	return (!defined $val || $val eq 'none')? $class->_log_level_value('min') - 1
		: ($val eq 'all')? $class->_log_level_value('max')
		: defined ($n= $class->_log_level_value($val))? $n
		: ($val =~ /^([A-Za-z]+)([-+][0-9]+)$/) && defined ($n= $class->_log_level_value(lc $1))? $n + $2
		: croak "unknown log level '$val'";
}

=head2 default_filter_stack

  my @hashes= $class->_default_filter_stack

Returns a list of hashrefs, where each is a map of category name to default
log level.  The category name '' is the global default.  The subclass's hash
is returned first, followed by those of its ancestors.

=head2 default_filter_for

  my $def= $class->_default_filter_for($category);

Class accessor for changing the global variable %class::_default_filter,
which inherits values from parent classes.  If category is omitted or ''
then it will return the global default.

=head2 set_default_filter_for

  $class->set_default_filter($category, 'trace');

Class accessor for changing the global variable %class::_default_filter.
If $category is undef or '' it will change the global default.
If the value is set to undef then the category will revert to any value in
the parent classes, or the global default.

=cut

our %_default_filter;
BEGIN {
	%_default_filter= ( '' => 'debug' );
}

sub _default_filter_stack {
	return ( \%_default_filter );
}

sub _init_default_filter_var {
	my $class= shift;
	local $@;
	eval '
		package '.$class.';
		our %_default_filter;
		sub _default_filter_stack { 
			return ( \%_default_filter, $_[0]->SUPER::_default_filter_stack );
		}
		1;' == 1
		or die my $e= $@;
}

sub default_filter_for {
	my ($class, $category)= @_;
	my @filter_stack= $class->_default_filter_stack;
	if (defined $category && length $category) {
		defined $_->{$category} && return $_->{$category}
			for @filter_stack;
	}
	defined $_->{''} && return $_->{''}
		for @filter_stack;
}

sub set_default_filter_for {
	my ($class, $category, $value)= @_;
	$class->_coerce_filter_level($value); # just testing for validity
	$category= '' unless defined $category;
	no strict 'refs';
	defined *{ $class . '::_default_filter' } or $class->_init_default_filter_var;
	${ $class . '::_default_filter' }{ $category }= $value;
}

=head1 LOGGING METHODS

This package provides default logging methods which all call back to a
'write_msg' method which must be defined in the subclass.

The methods convert all arguments into a single string according to the
Log::Any spec, so that subclasses don't have to deal with that.
This involves an attribute of 'dumper' to convert objects to strings
for the printf style functions.  We also define a default_dumper class
attribute which defaults to the method _default_dumper which does
"something sensible" to make things printable.

=head2 dumper

  use Log::Any::Adapter 'Filtered', dumper => sub { my $val=shift; ... };
  $log->dumper( sub { ... } );
  $class->dumper( sub { ... } );

Use a custom dumper function for converting perl data to strings.

Defaults to L</default_dumper>.

=head2 default_dumper

Returns \&_default_dumper.  Override this method as needed.  Even feel free to
override it from your main script like

  *Log::Any::Adapter::Filtered::default_dumper= sub { ... };

=cut

sub dumper {
	$_[0]{dumper}= $_[1] if @_ > 1;
	$_[0]{dumper} ||= $_[0]->default_dumper
}

sub default_dumper {
	return \&_default_dumper;
}

sub _default_dumper {
	my $val= shift;
	my $s= Data::Dumper->new([$val])->Indent(0)->Terse(1)->Useqq(1)->Quotekeys(0)
		->Maxdepth(Scalar::Util::blessed($val)? 2 : 4)->Sortkeys(1)->Dump;
	substr($s, 2000-3)= '...' if length $s > 2000;
	$s;
}

sub category { $_[0]{category} }

=head2 write_msg

  $self->write_msg( $level_name, $message_string )

This is an internal method which all the other logging methods call.
Subclasses should modify this as needed.

=cut

sub write_msg {
	my ($self, $level_name, $str)= @_;
	print STDERR "$level_name: $str\n";
}


sub init {
	my $self= shift;
	# Apply default dumper if not set
	$self->{dumper} ||= $self->default_dumper;
	# Apply default filter if not set
	defined $self->{filter}
		or $self->{filter}= $self->default_filter_for($self->{category});
	
	# Rebless to a "level filter" package, which is a subclass of this one
	# but with some methods replaced by empty subs.
	# If log level is less than the minimum value, we show all messages, so no need to rebless.
	(ref($self).'::Filter0')->can('info') or $self->_build_filtered_subclasses;
	my $filter_value= $self->_coerce_filter_level($self->filter);
	my $min_value= $self->_log_level_value('min');
	if ($filter_value >= $min_value) {
		my $max_value= $self->_log_level_value('max');
		$filter_value= $max_value if $filter_value > $max_value;
		my $pkg_suffix= $filter_value - $min_value;
		bless $self, ref($self)."::Filter$pkg_suffix"
	}
	
	return $self;
}


=head2 _build_logging_methods

This method builds all the standard logging methods from L<Log::Any/LOG LEVELS>.
This method is called on this package at compile time.

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

# Programmatically generate all the info, infof, is_info ... methods
sub _build_logging_methods {
	my $class= shift;
	$class= ref $class if Scalar::Util::blessed($class);
	my %seen;
	# We implement the stock methods, but also 'fatal' because in my mind, fatal is not
	# an alias for 'critical' and I want to see a prefix of "fatal" on messages.
	for my $method ( grep { !$seen{$_}++ } Log::Any->logging_methods(), 'fatal' ) {
		my ($impl, $printfn);
		if ($class->_log_level_value($method) >= $class->_log_level_value('info')) {
			# Standard logging.  Concatenate everything as a string.
			$impl= sub {
				(shift)->write_msg($method, join('', map { !defined $_? '<undef>' : $_ } @_));
			};
			# Formatted logging.  We dump data structures (because Log::Any says to)
			$printfn= sub {
				my $self= shift;
				$self->write_msg($method, sprintf((shift), map { !defined $_? '<undef>' : !ref $_? $_ : $self->dumper->($_) } @_));
			};
		} else {
			# Debug and trace logging.  For these, we trap exceptions and dump data structures
			$impl= sub {
				my $self= shift;
				local $@;
				eval { $self->write_msg($method, join('', map { !defined $_? '<undef>' : !ref $_? $_ : $self->dumper->($_) } @_)); 1 }
					or $self->warn("$@");
			};
			$printfn= sub {
				my $self= shift;
				local $@;
				eval { $self->write_msg($method, sprintf((shift), map { !defined $_? '<undef>' : !ref $_? $_ : $self->dumper->($_) } @_)); 1; }
					or $self->warn("$@");
			};
		}
			
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
	$class= ref $class if Scalar::Util::blessed($class);
	my $min_level= $class->_log_level_value('min');
	my $max_level= $class->_log_level_value('max');
	my $pkg_suffix_ofs= 0 - $min_level;
	
	# Create packages, inheriting from $class
	for ($min_level .. $max_level) {
		my $suffix= $_ - $min_level;
		no strict 'refs';
		push @{"${class}::Filter${suffix}::ISA"}, $class;
	}
	# For each method, mask it in any package of a higher filtering level
	for my $method (keys %level_map) {
		my $level= $class->_log_level_value($method);
		# Suppress methods in all higher filtering level packages
		for ($level .. $max_level) {
			my $suffix= $_ - $min_level;
			no strict 'refs';
			*{"${class}::Filter${suffix}::$method"}= sub {};
			*{"${class}::Filter${suffix}::${method}f"}= sub {};
			*{"${class}::Filter${suffix}::is_$method"}= sub { 0 }
		}
	}
}

BEGIN {
	__PACKAGE__->_build_logging_methods;
}

1;