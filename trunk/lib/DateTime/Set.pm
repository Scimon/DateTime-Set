# Copyright (c) 2003 Flavio Soibelmann Glock. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package DateTime::Set;

use strict;
use Carp;
use Params::Validate qw( validate SCALAR BOOLEAN OBJECT CODEREF ARRAYREF );
use DateTime 0.12;  # this is for version checking only
use DateTime::Duration;
use DateTime::Span;
use Set::Infinite 0.49;  
$Set::Infinite::PRETTY_PRINT = 1;   # enable Set::Infinite debug

use vars qw( $VERSION $neg_nanosecond );

$VERSION = '0.08';

use constant INFINITY     =>       100 ** 100 ** 100 ;
use constant NEG_INFINITY => -1 * (100 ** 100 ** 100);


BEGIN {
    # [FIXED] This doesn't work - might be a DT::Duration bug
    $neg_nanosecond = DateTime::Duration->new( nanoseconds => -1 );

    # $neg_nanosecond = DateTime::Duration->new( nanoseconds => 0 );
    # $neg_nanosecond->{nanoseconds} = -1;
}

# _add_callback( $set_infinite, $datetime_duration )
# Internal function
#
# Adds a value to a DateTime in a set.
#
# this is an internal callback - it is not an object method!
# Used by: add()
#
sub _add_callback {
    my $set = shift;   # $set is a Set::Infinite object
    my $dt = shift;    # $dt is a DateTime::Duration
    my $min = $set->min;
    if ( ref($min) ) {
        $min = $min->clone;
        $min->add_duration( $dt ) if ref($min);
    }
    my $result = $set->new( $min );
    return $result;
}

sub add { shift->add_duration( DateTime::Duration->new(@_) ) }

sub subtract { return shift->subtract_duration( DateTime::Duration->new(@_) ) }

sub subtract_duration { return $_[0]->add_duration( $_[1]->inverse ) }

sub add_duration {
    my ( $self, $dur ) = @_;

    # $dur should be cloned because if the set is a
    # recurrence then the callback will not be used
    # immediately - then $dur must be "immutable".

    my $result = $self->{set}->iterate( \&_add_callback, $dur->clone );

    ### this code would enable 'subroutine method' behaviour
    # $self->{set} = $result;
    # return $self;

    ### this code enables 'function method' behaviour
    my $set = $self->clone;
    $set->{set} = $result;
    return $set;
}

# note: the constructors must clone its DateTime parameters, such that
# the set elements become immutable

sub from_recurrence {
    my $class = shift;
    # note: not using validate() because this is too complex...
    my %args = @_;
    my %param;
    # Parameter renaming, such that we can use either
    #   recurrence => xxx   or   next => xxx, previous => xxx
    $param{next} = delete $args{recurrence}  or
    $param{next} = delete $args{next};
    $param{previous} = $args{previous}  and  delete $args{previous};
    $param{span} = $args{span}  and  delete $args{span};
    # they might be specifying a span using begin / end
    $param{span} = DateTime::Span->new( %args ) if keys %args;

    # otherwise, it is unbounded
    # $param{span}->{set} = Set::Infinite->new( NEG_INFINITY, INFINITY )
    #     unless exists $param{span}->{set};

    my $self = {};
    if ($param{next} || $param{previous}) {

        unless ( $param{previous} ) {
            my $data = {};
            $param{previous} =
                sub {
                    _callback_previous ( $_[0], $param{next}, $data );
                }
        }

        unless ( $param{current} ) {
            $param{current} =
                sub {
                    _callback_current ( $_[0], $param{next} );
                }
        }

        $self->{next} =     $param{next}     if $param{next};
        $self->{current} =  $param{current}  if $param{current};
        $self->{previous} = $param{previous} if $param{previous};

        $self->{set} = _recurrence_callback( 
            Set::Infinite->new( NEG_INFINITY, INFINITY ), 
            $param{next}, 
            $param{current},
            $param{previous} );
        bless $self, $class;

        return $self->intersection( $param{span} )
             if $param{span};
    }
    else {
        die "Not enough arguments in from_recurrence()";
    }
    return $self;
}

sub from_datetimes {
    my $class = shift;
    my %args = validate( @_,
                         { dates => 
                           { type => ARRAYREF,
                           },
                         }
                       );
    my $self = {};
    $self->{set} = Set::Infinite->new;
    # possible optimization: sort dates and use "push"
    for( @{ $args{dates} } ) {
        $self->{set} = $self->{set}->union( $_->clone );
    }

    bless $self, $class;
    return $self;
}

sub empty_set {
    my $class = shift;

    return bless { set => Set::Infinite->new }, $class;
}

sub clone { 
    bless { 
        set => $_[0]->{set}->copy,
        }, ref $_[0];
}

# _recurrence_callback( 
#     $set_infinite, \&callback_next, \&callback_current, \&callback_previous )
#
# Internal function
#
# Generates "recurrences" from a callback.
# These recurrences are simple lists of dates.
#
# this is an internal callback - it is not an object method!
# Used by: new( next => )
#
# The recurrence generation is based on an idea from Dave Rolsky.
#
sub _recurrence_callback {
    # warn "_recurrence args: @_";
    # note: $_[0] is a Set::Infinite object
    my ( $set, $callback_next, $callback_current, $callback_previous ) = @_;    

    # test for the special case when we have an infinite recurrence

    if ($set->min == NEG_INFINITY ||
        $set->max == INFINITY) {

        return _setup_infinite_recurrence( 
            $set, $callback_next, $callback_current, $callback_previous );
    }
    else {

        return _setup_finite_recurrence( 
            $set, $callback_next, $callback_current, $callback_previous );
    }
}

sub _setup_infinite_recurrence {
    my ( $set, $callback_next, $callback_current, $callback_previous ) = @_;

    # warn "_recurrence called with inf argument";

    # these should never happen, but we have to test anyway:
    return $set->new( NEG_INFINITY ) 
        if $set->min == NEG_INFINITY && $set->max == NEG_INFINITY;
    return $set->new( INFINITY ) 
        if $set->min == INFINITY && $set->max == INFINITY;

    # return an internal "_function", such that we can 
    # backtrack and solve the equation later.
    $set = $set->copy;  # prevent circular references
    my $func = $set->_function( 'iterate', 
        sub {
            _recurrence_callback( 
               $_[0], $callback_next, $callback_current, $callback_previous );
        }
    );

    # -- begin hack

    # This code will be removed, as soon as Set::Infinite can deal 
    # directly with this type of set generation.
    # Since this is a Set::Infinite "custom" function, the iterator 
    # will need some help.

    # Here we are setting up the first() cache directly,
    # because Set::Infinite has no hint of how to do it.
    if ($set->min == INFINITY || $set->min == NEG_INFINITY) {
        # warn "RECURR: start in ".$set->min;
        # $func->copy make it recursive without circular references
        $func->{first} = [ $set->new( $set->min ), $func->copy ];
    }
    else {
        my $min = $set->min;
        $min = $callback_current->( $min->clone );
        $func->{min} = [ $min, 1 ];

        my $next = $callback_next->( $min->clone );
        my $next_set = $set->intersection( $next->clone, INFINITY );

        my @first = ( 
            $set->new( $min->clone ), 
            $next_set->_function( 'iterate',
                sub {
                    _recurrence_callback( 
                        $_[0], $callback_next, $callback_current, $callback_previous );
                } ) );
        $func->{first} = \@first;
    }

    # Now are setting up the last() cache directly
    if ($set->max == INFINITY || $set->max == NEG_INFINITY) {
        # warn "RECURR: end in ".$set->max;
        # $func->copy make it recursive without circular references
        $func->{last} = [ $set->new( $set->max ), $func->copy ];
    }
    else {
        my $max = $set->max;
        $max = $callback_current->( $max->clone );
        $max = $callback_previous->( $max->clone ) unless $max == $set->max;
        $func->{max} = [ $max, 1 ];
 
        my $previous = $callback_previous->( $max->clone );
        my $previous_set = $set->intersection( NEG_INFINITY, $previous->clone );
        my @last = (
            $set->new( $max->clone ),
            $previous_set->_function( 'iterate',
                sub {
                    _recurrence_callback( 
                        $_[0], $callback_next, $callback_current, $callback_previous );
                } ) );
        $func->{last} = \@last;
    }

    # -- end hack

    return $func;
}

sub _setup_finite_recurrence {
    my ( $set, $callback_next, $callback_current, $callback_previous ) = @_;
    # this is a finite recurrence - generate it.
    my $min = $set->min;
    return unless defined $min;
    my $max = $set->max;
    $min = $callback_current->( $min );
    my $result = $set->new();
    while (1) {
        return $result if ! defined $min || $min > $max;
        $result = $result->union( $min->clone );
        $min = $callback_next->( $min );
    };
}

# default callback that returns the 
# "current" value in a callback recurrence.
# Does not change $_[0]
#
sub _callback_current {
    # ($value, $callback_next)
    return $_[1]->( $_[0] + $neg_nanosecond );
}

# default callback that returns the 
# "previous" value in a callback recurrence.
#
# This is used to simulate a 'previous' callback,
# when then 'previous' argument in 'from_recurrence' is missing.
#
sub _callback_previous {
    my ($value, $callback_next, $callback_info) = @_; 
    my $previous = $value->clone;

    my $freq = $callback_info->{freq};
    unless (defined $freq) { 
        # This is called just once, to setup the recurrence frequency
        # The program will warn() if it this is not working properly.

        my $previous = $callback_next->( $value->clone );
        my $next =     $callback_next->( $previous->clone );

my $FIXED = <<'___END_REMOVE';
        $freq = $next - $previous;
        # my %freq = $freq->deltas;
        # $freq{$_} = - abs ( int( $freq{$_} * 2 ) ) for keys %freq; 

        # TODO: don't use DT::Duration internals here.
        # - find out why it doesn't work with normal multiplication.
        for ( keys %$freq ) {
            next if $_ eq 'eom_mode';
            next if $_ eq 'sign';
            $freq->{$_} = - abs ( int( $freq->{$_} * 2 ) );
        }

        # my @freq = %freq;
        # warn "freq 1 is @freq";

        # $freq = new DateTime::Duration( %freq );
___END_REMOVE

        $freq = 2 * ( $previous - $next );

        # save it for future use with this same recurrence
        $callback_info->{freq} = $freq;

        # my @freq = $freq->deltas;
        # warn "freq 2 is @freq";
    }

    $previous->add_duration( $freq );  
    # warn "callback is $callback";
    # warn "current is ".$value->ymd." previous is ".$previous->ymd;
    $previous = $callback_next->( $previous );
    # warn " previous got ".$previous->ymd;
    if ($previous >= $value) {
        # This error might happen if the event frequency oscilates widely
        # (more than 100% of difference from one interval to next)
        my @freq = $freq->deltas;
        print STDERR "_callback_previous: Delta components are: @freq\n";
        warn "_callback_previous: iterator can't find a previous value, got ".$previous->ymd." before ".$value->ymd;

        # retry
        # $previous->add_duration( 2 * $freq );
        # $previous = $callback_next->( $previous );
        # die "Still getting ".$previous->ymd if ($previous >= $value);
    }
    my $previous1;
    while (1) {
        $previous1 = $previous->clone;
        $previous = $callback_next->( $previous );
        return $previous1 if $previous >= $value;
    }
}


sub iterator {
    my $self = shift;

    my %args = @_;
    my $span;
    $span = delete $args{span};
    $span = DateTime::Span->new( %args ) if %args;

    return $self->intersection( $span ) if $span;
    return $self->clone;
}


# next() gets the next element from an iterator()
# next( $dt ) returns the next element after a datetime.
sub next {
    my $self = shift;
    return undef unless ref( $self->{set} );

    if ( @_ ) {
        if ( $self->{next} )
        {
            return $self->{next}->( $_[0]->clone );
        }
        else {
            my $span = DateTime::Span->from_datetimes( after => $_[0] );
            return $self->intersection( $span )->next;
        }
    }

    my ($head, $tail) = $self->{set}->first;
    $self->{set} = $tail;
    return $head->min if defined $head;
    return $head;
}

# previous() gets the last element from an iterator()
# previous( $dt ) returns the previous element before a datetime.
sub previous {
    my $self = shift;
    return undef unless ref( $self->{set} );

    if ( @_ ) {
        if ( exists $self->{previous} ) 
        {
            return $self->{previous}->( $_[0]->clone );
        }
        else {
            my $span = DateTime::Span->from_datetimes( before => $_[0] );
            return $self->intersection( $span )->previous;
        }
    }

    my ($head, $tail) = $self->{set}->last;
    $self->{set} = $tail;
    return $head->max if defined $head;
    return $head;
}

# "current" means less-or-equal to a DateTime
sub current {
    my $self = shift;

    return undef unless ref( $self->{set} );

    if ( $self->{current} )
    {
        my $tmp = $self->{current}->( $_[0] );
        return $tmp if $tmp == $_[0];
        return $self->previous( $_[0] );
    }

    return $_[0] if $self->contains( $_[0] );
    $self->previous( $_[0] );
}

sub closest {
    my $self = shift;
    # return $_[0] if $self->contains( $_[0] );
    my $dt1 = $self->current( $_[0] );
    my $dt2 = $self->next( $_[0] );

    # removed - in order to avoid duration comparison
    # return $dt1 if ( $_[0] - $dt1 ) <= ( $dt2 - $_[0] );

    my $delta = $_[0] - $dt1;
    return $dt1 if ( $dt2 - $delta ) >= $_[0];

    return $dt2;
}


sub as_list {
    my ($self) = shift;
    return undef unless ref( $self->{set} );

    my %args = @_;
    my $span;
    $span = delete $args{span};
    $span = DateTime::Span->new( %args ) if %args;

    my $set = $self->{set};
    $set = $set->intersection( $span->{set} ) if $span;

    return undef if $set->is_too_complex;  # undef = no begin/end
    return if $set->is_null;  # nothing = empty
    my @result;
    # we should extract _copies_ of the set elements,
    # such that the user can't modify the set indirectly
    for ( @{ $set->{list}  } ) {
        push @result, $_->{a}->clone
            if ref( $_->{a} );   # we don't want to return INFINITY value
    }
    return @result;
}

# Set::Infinite methods

my $max_iterate = 20;

sub intersection {
    my ($set1, $set2) = @_;
    my $class = ref($set1);
    my $tmp = $class->empty_set();
    $set2 = $class->from_datetimes( dates => [ $set2 ] ) unless $set2->can( 'union' );

    # It looks like this is not worth optimizing - it never happens in tests
    # if ( ( $set1->{next} && $set2->{method} eq 'intersection' ) ||
    #      ( $set2->{next} && $set1->{method} eq 'intersection' ) )
    # {
    #     warn "optimize this!";
    # }

    # optimization - use function composition if both sets are recurrences
    if ( $set1->{next} && $set2->{next} ) 
    {
        # TODO: add tests

        # warn "compose intersection";
        return $class->from_recurrence(
                  next =>  sub {
                               # intersection of parent 'next' callbacks
                               my $arg = shift;
                               my ($tmp1, $next1, $next2);
                               my $iterate = 0;
                               while(1) { 
                                   $next1 = $set1->{next}->( $arg->clone );
                                   $next2 = $set2->{current}->( $next1 );
                                   return $next1 if $next1 == $next2;
                            
                                   $next2 = $set2->{next}->( $arg );
                                   $tmp1 = $set1->{current}->( $next2 );  
                                   return $next2 if $next2 == $tmp1;
                                  
                                   $arg = $next1 > $next2 ? $next1 : $next2;
                                   return if $iterate++ == $max_iterate;
                               }
                           },
                  previous => sub {
                               # intersection of parent 'previous' callbacks
                               my $arg = shift;
                               my ($tmp1, $previous1, $previous2);
                               my $iterate = 0;
                               while(1) { 
                                   $previous1 = $set1->{previous}->( $arg->clone );
                                   $previous2 = $set2->{current}->( $previous1 ); 
                                   return $previous1 if $previous1 == $previous2;

                                   $previous2 = $set2->{previous}->( $arg ); 
                                   $tmp1 = $set1->{current}->( $previous2 ); 
                                   return $previous2 if $previous2 == $tmp1;

                                   $arg = $previous1 < $previous2 ? $previous1 : $previous2;
                                   return if $iterate++ == $max_iterate;
                               }
                           },
               );
    }

    $tmp->{set} = $set1->{set}->intersection( $set2->{set} );
    return $tmp;
}

sub intersects {
    my ($set1, $set2) = @_;
    my $class = ref($set1);
    $set2 = $class->from_datetimes( dates => [ $set2 ] ) unless $set2->can( 'union' );
    return $set1->{set}->intersects( $set2->{set} );
}

sub contains {
    my ($set1, $set2) = @_;
    my $class = ref($set1);
    $set2 = $class->from_datetimes( dates => [ $set2 ] ) unless $set2->can( 'union' );
    return $set1->{set}->contains( $set2->{set} );
}

sub union {
    my ($set1, $set2) = @_;
    my $class = ref($set1);
    my $tmp = $class->empty_set();
    $set2 = $class->from_datetimes( dates => [ $set2 ] ) unless $set2->can( 'union' );

    if ( $set1->{next} && $set2->{next} )
    {
        # TODO: add tests

        # warn "compose union";
        return $class->from_recurrence(
                  next =>  sub {
                               # union of parent 'next' callbacks
                               my $arg = shift;
                               my ($next1, $next2);
                               $next1 = $set1->{next}->( $arg->clone );
                               $next2 = $set2->{next}->( $arg );
                               return $next1 < $next2 ? $next1 : $next2;
                           },
                  previous => sub {
                               # union of parent 'previous' callbacks
                               my $arg = shift;
                               my ($previous1, $previous2);
                               $previous1 = $set1->{previous}->( $arg->clone );
                               $previous2 = $set2->{previous}->( $arg ); 
                               return $previous1 > $previous2 ? $previous1 : $previous2;;
                           },
               );
    }

    $tmp->{set} = $set1->{set}->union( $set2->{set} );
    bless $tmp, 'DateTime::SpanSet' 
        if $set2->isa('DateTime::Span') or $set2->isa('DateTime::SpanSet');
    return $tmp;
}

sub complement {
    my ($set1, $set2) = @_;
    my $class = ref($set1);
    my $tmp = $class->empty_set();
    if (defined $set2) {
        $set2 = $class->from_datetimes( dates => [ $set2 ] ) unless $set2->can( 'union' );
        # TODO: "compose complement";
        $tmp->{set} = $set1->{set}->complement( $set2->{set} );
    }
    else {
        $tmp->{set} = $set1->{set}->complement;
    }
    bless $tmp, 'DateTime::SpanSet' unless @_;
    return $tmp;
}

sub min { 
    my $tmp = $_[0]->{set}->min;
    ref($tmp) ? $tmp->clone : $tmp; 
}

sub max { 
    my $tmp = $_[0]->{set}->max;
    ref($tmp) ? $tmp->clone : $tmp; 
}

# returns a DateTime::Span
sub span {
  my $set = $_[0]->{set}->span;
  bless { set => $set }, 'DateTime::Span';
  return $set;
}

# unsupported Set::Infinite methods

sub size { die "size() not supported - would be zero!"; }
sub offset { die "offset() not supported"; }
sub quantize { die "quantize() not supported"; }

1;

__END__

=head1 NAME

DateTime::Set - Datetime sets and set math

=head1 SYNOPSIS

    use DateTime;
    use DateTime::Set;

    $date1 = DateTime->new( year => 2002, month => 3, day => 11 );
    $set1 = DateTime::Set->from_datetimes( dates => [ $date1 ] );
    #  set1 = 2002-03-11

    $date2 = DateTime->new( year => 2003, month => 4, day => 12 );
    $set2 = DateTime::Set->from_datetimes( dates => [ $date1, $date2 ] );
    #  set2 = 2002-03-11, and 2003-04-12

    # a 'monthly' recurrence:
    $set = DateTime::Set->from_recurrence( 
        recurrence => sub {
            $_[0]->truncate( to => 'month' )->add( months => 1 )
        },
        span => $date_span1,    # optional span
    );

    $set = $set1->union( $set2 );         # like "OR", "insert", "both"
    $set = $set1->complement( $set2 );    # like "delete", "remove"
    $set = $set1->intersection( $set2 );  # like "AND", "while"
    $set = $set1->complement;             # like "NOT", "negate", "invert"

    if ( $set1->intersects( $set2 ) ) { ...  # like "touches", "interferes"
    if ( $set1->contains( $set2 ) ) { ...    # like "is-fully-inside"

    # data extraction 
    $date = $set1->min;           # first date of the set
    $date = $set1->max;           # last date of the set

    $iter = $set1->iterator;
    while ( $dt = $iter->next ) {
        print $dt->ymd;
    };

=head1 DESCRIPTION

DateTime::Set is a module for date/time sets.  It can be used to
handle two different types of sets.

The first is a fixed set of predefined datetime objects.  For example,
if we wanted to create a set of dates containing the birthdays of
people in our family.

The second type of set that it can handle is one based on the idea of
a recurrence, such as "every Wednesday", or "noon on the 15th day of
every month".  This type of set can have fixed starting and ending
datetimes, but neither is required.  So our "every Wednesday set"
could be "every Wednesday from the beginning of time until the end of
time", or "every Wednesday after 2003-03-05 until the end of time", or
"every Wednesday between 2003-03-05 and 2004-01-07".

=head1 METHODS

=over 4

=item * from_datetimes

Creates a new set from a list of dates.

   $dates = DateTime::Set->from_datetimes( dates => [ $dt1, $dt2, $dt3 ] );

=item * from_recurrence

Creates a new set specified via a "recurrence" callback.

    $months = DateTime::Set->from_recurrence( 
        span => $dt_span_this_year,    # optional span
        recurrence => sub { 
            $_[0]->truncate( to => 'month' )->add( months => 1 ) 
        }, 
    );

The C<span> parameter is optional. It must be a C<DateTime::Span> object.

The span can also be specified using C<begin> / C<after> and C<before>
/ C<end> parameters, as in the C<DateTime::Span> constructor.  In this
case, if there is a C<span> parameter it will be ignored.

    $months = DateTime::Set->from_recurrence(
        after => $dt_now,
        recurrence => sub {
            $_[0]->truncate( to => 'month' )->add( months => 1 )
        },
    );

The recurrence will be passed a single parameter, a DateTime.pm
object.  The recurrence must generate the I<next> event before or
after that object.  There is no guarantee as to what the object will
be set to, only that it will be greater or lesser than the last object
passed to the recurrence.

For example, if you wanted a recurrence that generated datetimes in
increments of 30 seconds would look like this:

  sub every_30_seconds {
      my $dt = shift;

      $dt->truncate( to => 'seconds' );

      if ( $dt->second < 30 ) {
          $dt->add( seconds => 30 - $dt->second );
      } else {
          $dt->add( seconds => 60 - $dt->second );
      }
  }

Of course, this recurrence ignores leap seconds, but we'll leave that
as an exercise for the reader ;)

It is also possible to create a recurrence by specifying both
'next' and 'previous' callbacks.

See also C<DateTime::Event::Recurrence> and the other C<DateTime::Event>
modules for generating specialized recurrences, such as sunrise and sunset time, 
and holidays.

=item * empty_set

Creates a new empty set.

=item * add_duration( $duration )

    $dtd = new DateTime::Duration( year => 1 );
    $new_set = $set->add( duration => $dtd );

This method returns a new set which is the same as the existing set
with the specified duration added to every element of the set.

=item * add

    $meetings_2004 = $meetings_2003->add( years => 1 );

This method is syntactic sugar around the C<add_duration()> method.

=item * subtract_duration( $duration_object )

When given a C<DateTime::Duration> object, this method simply calls
C<invert()> on that object and passes that new duration to the
C<add_duration> method.

=item * subtract( DateTime::Duration->new parameters )

Like C<add()>, this is syntactic sugar for the C<subtract_duration()>
method.

=item * min / max

The first and last dates in the set.  These methods may return
C<undef> if the set is empty.  It is also possible that these methods
may return a scalar containing infinity or negative infinity.

=item * span

Returns the total span of the set, as a C<DateTime::Span> object.

=item * iterator / next / previous

These methods can be used to iterate over the dates in a set.

    $iter = $set1->iterator;
    while ( $dt = $iter->next ) {
        print $dt->ymd;
    }

The boundaries of the iterator can be limited by passing it a C<span>
parameter.  This should be a C<DateTime::Span> object which delimits
the iterator's boundaries.  Optionally, instead of passing an object,
you can pass any parameters that would work for one of the
C<DateTime::Span> class's constructors, and an object will be created
for you.

Obviously, if the span you specify does is not restricted both at the
start and end, then your iterator may iterate forever, depending on
the nature of your set.  User beware!

The C<next()> or C<previous()> method will return C<undef> when there
are no more datetimes in the iterator.

=item * as_list

Returns a list of C<DateTime> objects.

  my @dt = $set->as_list( span => $span );

Just as with the C<iterator()> method, the C<as_list()> method can be
limited by a span.  If a set is specified as a recurrence and has no
fixed begin and end datetimes, then C<as_list> will return C<undef>
unless you limit it with a span.  Please note that this is explicitly
not an empty list, since an empty list is a valid return value for
empty sets!

=item * union / intersection / complement

Set operations may be performed not only with C<DateTime::Set>
objects, but also with C<DateTime::Span>, C<DateTime::SpanSet>,
and C<DateTime> objects.

    $set = $set1->union( $set2 );         # like "OR", "insert", "both"
    $set = $set1->complement( $set2 );    # like "delete", "remove"
    $set = $set1->intersection( $set2 );  # like "AND", "while"
    $set = $set1->complement;             # like "NOT", "negate", "invert"

The C<union> of a C<DateTime::Set> with a C<DateTime::Span> or a
C<DateTime::SpanSet> object returns a C<DateTime::SpanSet> object.

All other operations will always return a C<DateTime::Set>.

=item * intersects / contains

These set operations result in a boolean value.

    if ( $set1->intersects( $set2 ) ) { ...  # like "touches", "interferes"
    if ( $set1->contains( $dt ) ) { ...    # like "is-fully-inside"

These methods can accept a C<DateTime>, C<DateTime::Set>,
C<DateTime::Span>, or C<DateTime::SpanSet> object as an argument.

=item * previous / next / current / closest

  my $dt = $set->next( $dt );

  my $dt = $set->previous( $dt );

These methods are used to find a set member relative to a given
datetime.

The C<current()> method returns C<$dt> if $dt is an event, otherwise
it returns the previous event.

The C<closest()> method returns C<$dt> if $dt is an event, otherwise
it returns the closest event (previous or next).

All of these methods may return C<undef> if there is no matching
datetime in the set.

=back

=head1 SUPPORT

Support is offered through the C<datetime@perl.org> mailing list.

Please report bugs using rt.cpan.org

=head1 AUTHOR

Flavio Soibelmann Glock <fglock@pucrs.br>

The API was developed together with Dave Rolsky and the DateTime Community.

=head1 COPYRIGHT

Copyright (c) 2003 Flavio Soibelmann Glock. All rights reserved.
This program is free software; you can distribute it and/or
modify it under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file
included with this module.

=head1 SEE ALSO

Set::Infinite

For details on the Perl DateTime Suite project please see
L<http://datetime.perl.org>.

=cut

