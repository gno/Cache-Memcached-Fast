# See the end of the file for copyright and license.
#

package Cache::Memcached::Fast;

use 5.006;
use strict;
use warnings;


=head1 NAME

Cache::Memcached::Fast - Perl client for B<memcached>, in C language

=head1 VERSION

Version 0.07

=cut

our $VERSION = '0.07';


=head1 SYNOPSIS

  use Cache::Memcached::Fast;

  my $memd = new Cache::Memcached::Fast({
      servers => [ { address => 'localhost:11211', weight => 2.5 },
                   '192.168.254.2:11211',
                   { address => '/path/to/unix.sock' } ],
      namespace => 'my:',
      connect_timeout => 0.2,
      io_timeout => 0.5,
      close_on_error => 1,
      compress_threshold => 100_000,
      compress_ratio => 0.9,
      compress_algo => 'deflate',
      max_failures => 3,
      failure_timeout => 2,
      ketama_points => 150,
      nowait => 1,
      utf8 => ($^V >= 5.008001 ? 1 : 0),
  });

  # Get server versions.
  my $versions = $memd->server_versions;
  while (my ($server, $version) = each %$versions) {
      #...
  }

  # Store scalars.
  $memd->add('skey', 'text');
  $memd->add_multi(['skey2', 'text2'], ['skey3', 'text3', 10]);

  $memd->replace('skey', 'val');
  $memd->replace_multi(['skey2', 'val2'], ['skey3', 'val3']);

  $memd->set('nkey', 5);
  $memd->set_multi(['nkey2', 10], ['skey3', 'text', 5]);

  # Store arbitrary Perl data structures.
  my %hash = (a => 1, b => 2);
  my @list = (1, 2);
  $memd->set('hash', \%hash);
  $memd->set_multi(['scalar', 1], ['list', \@list]);

  # Add to strings.
  $memd->prepend('skey', 'This is a ');
  $memd->prepend_multi(['skey2', 'This is a '], ['skey3', 'prefix ']);
  $memd->append('skey', 'ue.');
  $memd->prepend_multi(['skey2', 'ue.'], ['skey3', ' suffix']);

  # Do arithmetic.
  $memd->incr('nkey', 10);
  print "OK\n" if $memd->decr('nkey', 3) == 12;

  my @counters = qw(c1 c2);
  $memd->incr_multi(['c3', 2], @counters, ['c4', 10]);

  # Retrieve values.
  my $val = $memd->get('skey');
  print "OK\n" if $val eq 'This is a value.';
  my $href = $memd->get_multi('hash', 'nkey');
  print "OK\n" if $href->{hash}->{b} == 2 and $href->{nkey} == 12;

  # Do atomic test-and-set operations.
  my $cas_val = $memd->gets('nkey');
  $$cas_val[1] = 0 if $$cas_val[1] == 12;
  if ($memd->cas('nkey', @$cas_val)) {
      print "OK, value updated\n";
  } else {
      print "Update failed, probably another client"
          . " has updated the value\n";
  }

  # Delete some data.
  $memd->delete('skey');

  my @keys = qw(k1 k2 k3);
  $memd->delete_multi(@keys, ['k5', 20]);

  # Wait for all commands that were executed in nowait mode.
  $memd->nowait_push;

  # Wipe out all cached data.
  $memd->flush_all;


=head1 DESCRIPTION

B<Cache::Memcahced::Fast> is a Perl client for B<memcached>, a memory
cache daemon (L<http://www.danga.com/memcached/>).  Module core is
implemented in C and tries hard to minimize number of system calls and
to avoid any key/value copying for speed.  As a result, it has very
low CPU consumption.

API is largely compatible with L<Cache::Memcached|Cache::Memcached>,
original pure Perl client, most users of the original module may start
using this module by installing it and adding I<"::Fast"> to the old
name in their scripts (see L</"Compatibility with Cache::Memcached">
below for full details).


=cut


use Carp;
use Storable;

require XSLoader;
XSLoader::load('Cache::Memcached::Fast', $VERSION);


# BIG FAT WARNING: Perl assignment copies the value, so below we try
# to avoid any copying by passing references around.  Any code
# modifications should try to preserve this.


my %compress_algo;


BEGIN {
    my @algo = (
        'Gzip'        =>  'Gunzip',
        'Zip'         =>  'Unzip',
        'Bzip2'       =>  'Bunzip2',
        'Deflate'     =>  'Inflate',
        'RawDeflate'  =>  'RawInflate',
        'Lzop'        =>  'UnLzop',
        'Lzf'         =>  'UnLzf',
    );

    while (my ($c, $u) = splice(@algo, 0, 2)) {
        my $key = lc $c;
        my $val = ["IO::Compress::$c", "IO::Uncompress::$u",
                   "IO::Compress::${c}::" . lc $c,
                   "IO::Uncompress::${u}::" . lc $u];
        $compress_algo{$key} = $val;
    }
}


use fields qw(
    _xs
);


=head1 CONSTRUCTOR

=over

=item I<new>

  my $memd = new Cache::Memcached::Fast($params);

Create new client object.  I<$params> is a reference to a hash with
client parameters.  Currently recognized keys are:

=over

=item I<servers>

  servers => [ { address => 'localhost:11211', weight => 2.5 },
               '192.168.254.2:11211',
               { address => '/path/to/unix.sock' } ],
  (default: none)

The value is a reference to an array of server addresses.  Each
address is either a scalar, a hash reference, or an array reference
(for compatibility with Cache::Memcached, deprecated).  If hash
reference, the keys are I<address> (scalar) and I<weight> (positive
rational number).  The server address is in the form I<host:port> for
network TCP connections, or F</path/to/unix.sock> for local Unix
socket connections.  When weight is not given, 1 is assumed.  Client
will distribute keys across servers proportionally to server weights.

If you want to get key distribution compatible with Cache::Memcached,
all server weights should be integer, and their sum should be less
than 32768.


=item I<namespace>

  namespace => 'my::'
  (default: '')

The value is a scalar that will be prepended to all key names passed
to the B<memcached> server.  By using different namespaces clients
avoid interference with each other.


=item I<nowait>

  nowait => 1
  (default: disabled)

The value is a boolean which enables (true) or disables (false)
I<nowait> mode.  If enabled, when you call a method that only returns
its success status (like L</set>), B<I<in a void context>>, it sends
the request to the server and returns immediately, not waiting the
reply.  This avoids the round-trip latency at a cost of uncertain
command outcome.

Internally there is a counter of how many outstanding replies there
should be, and on any command the client reads and discards any
replies that have already arrived.  When you later execute some method
in a non-void context, all outstanding replies will be waited for, and
then the reply for this command will be read and returned.


=item I<connect_timeout>

  connect_timeout => 0.7
  (default: 0.25 seconds)

The value is a non-negative rational number of seconds to wait for
connection to establish.  Applies only to network connections.  Zero
disables timeout, but keep in mind that operating systems have their
own heuristic connect timeout.

Note that network connect process consists of several steps:
destination host address lookup, which may return several addresses in
general case (especially for IPv6, see
L<http://people.redhat.com/drepper/linux-rfc3484.html> and
L<http://people.redhat.com/drepper/userapi-ipv6.html>), then the
attempt to connect to one of those addresses.  I<connect_timeout>
applies only to one such connect, i.e. to one I<connect(2)>
call.  Thus overall connect process may take longer than
I<connect_timeout> seconds, but this is unavoidable.


=item I<io_timeout> (or deprecated I<select_timeout>)

  io_timeout => 0.5
  (default: 1.0 seconds)

The value is a non-negative rational number of seconds to wait before
giving up on communicating with the server(s).  Zero disables timeout.

Note that for commands that communicate with more than one server
(like L</get_multi>) the timeout applies per server set, not per each
server.  Thus it won't expire if one server is quick enough to
communicate, even if others are silent.  But if some servers are dead
those alive will finish communication, and then dead servers would
timeout.


=item I<close_on_error>

  close_on_error => 0
  (default: enabled)

The value is a boolean which enables (true) or disables (false)
I<close_on_error> mode.  When enabled, any error response from the
B<memcached> server would make client close the connection.  Note that
such "error response" is different from "negative response".  The
latter means the server processed the command and yield negative
result.  The former means the server failed to process the command for
some reason.  I<close_on_error> is enabled by default for safety.
Consider the following scenario:

=over

=item 1 Client want to set some value, but mistakenly sends malformed
        command (this can't happen with current module of course ;)):

  set key 10\r\n
  value_data\r\n

=item 2 Memcahced server reads first line, 'set key 10', and can't
        parse it, because there's wrong number of tokens in it.  So it
        sends

  ERROR\r\n

=item 3 Then the server reads 'value_data' while it is in
        accept-command state!  It can't parse it either (hopefully),
        and sends another

  ERROR\r\n

=back

But the client expects one reply per command, so after sending the
next command it will think that the second 'ERROR' is a reply for this
new command.  This means that all replies will shift, including
replies for L</get> commands!  By closing the connection we eliminate
such possibility.

When connection dies, or the client receives the reply that it can't
understand, it closes the socket regardless the I<close_on_error>
setting.


=item I<compress_threshold>

  compress_threshold => 10_000
  (default: -1)

The value is an integer.  When positive it denotes the threshold size
in bytes: data with the size equal or larger than this should be
compressed.  See L</compress_ratio> and L</compress_algo> below.

Negative value disables compression.


=item I<compress_ratio>

  compress_ratio => 0.9
  (default: 0.8)

The value is a fractional number between 0 and 1.  When
L</compress_threshold> triggers the compression, compressed size
should be less or equal to S<(original-size * I<compress_ratio>)>.
Otherwise the data will be stored uncompressed.


=item I<compress_algo>

  compress_algo => 'bzip2'
  (default: 'gzip')

The value is a scalar with the name of the compression algorithm
(currently known are 'gzip', 'zip', 'bzip2', 'deflate', 'rawdeflate',
'lzop', 'lzf').  You have to have corresponding IO::Compress::<Algo>
installed, otherwise the module will give a warning and compression
will be disabled.


=item I<max_failures>

  max_failures => 3
  (default: 0)

The value is a non-negative integer.  When positive, if there happened
I<max_failures> in I<failure_timeout> seconds, the client does not try
to connect to this particular server for another I<failure_timeout>
seconds.  Value of zero disables this behaviour.


=item I<failure_timeout>

  failure_timeout => 30
  (default: 10 seconds)

The value is a positive integer number of seconds.  See
L</max_failures>.


=item I<ketama_points>

  ketama_points => 150
  (default: 0)

The value is a non-negative integer.  When positive, enables the
B<Ketama> consistent hashing algorithm
(L<http://www.last.fm/user/RJ/journal/2007/04/10/392555/>), and
specifies the number of points the server with weight 1 will be mapped
to.  Thus each server will be mapped to S<I<ketama_points> *
I<weight>> points in continuum.  Larger value will result in more
uniform distribution.  Note that the number of internal bin
structures, and hence memory consumption, will be proportional to sum
of such products.  But bin structures themselves are small (two
integers each), so you probably shouldn't worry.

Zero value disables the Ketama algorithm.  See also server weight in
L</servers> above.


=item I<utf8> (B<experimental, Perl 5.8.1 and later only>)

  utf8 => 1
  (default: disabled)

The value is a boolean which enables (true) or disables (false) the
conversion of Perl character strings to octet sequences in UTF-8
encoding on store, and the reverse conversion on fetch (when the
retrieved data is marked as being UTF-8 octet sequence).  See
L<perlunicode|perlunicode>.


=back

=back

=cut

sub new {
    my Cache::Memcached::Fast $self = shift;
    my ($conf) = @_;

    $self = fields::new($self) unless ref($self);

    my $compress = $compress_algo{lc($conf->{compress_algo} || 'gzip')};
    if (defined $compress) {
        if (eval "require $compress->[0]"
            and eval "require $compress->[1]") {
            no strict 'refs';
            $conf->{compress_methods} = [ map { \&$_ } @{$compress}[2, 3] ];
        } else {
            undef $conf->{compress_methods};
        }
    } else {
        carp "Compress algorithm '$conf->{compress_algo}' is not known to"
            . " Cache::Memcached::Fast, disabling compression";
        undef $conf->{compress_methods};
        $conf->{compress_threshold} = -1;
    }

    if ($conf->{utf8} and $^V < 5.008001) {
        carp "'utf8' may be enabled only for Perl >= 5.8.1, disabled";
        undef $conf->{utf8};
    }

    $self->{_xs} = new Cache::Memcached::Fast::_xs($conf);

    return $self;
}


=head1 METHODS

=over

=item C<enable_compress>

  $memd->enable_compress($enable);

Enable compression when boolean I<$enable> is true, disable when
false.

Note that you can enable compression only when you set
L</compress_threshold> to some positive value and L</compress_algo>
holds the name of a known compression algorithm.

I<Return:> none.

=cut

sub enable_compress {
    my Cache::Memcached::Fast $self = shift;
    $self->{_xs}->enable_compress(@_);
}


=item C<set>

  $memd->set($key, $value);
  $memd->set($key, $value, $expiration_time);

Store the I<$value> on the server under the I<$key>.  I<$key> should
be a scalar.  I<$value> should be defined and may be of any Perl data
type.  When it is a reference, the referenced Perl data structure will
be transparently serialized with L<Storable|Storable> module.

Optional I<$expiration_time> is a positive integer number of seconds
after which the value will expire and wouldn't be accessible any
longer.

I<Return:> boolean, true for positive server reply, false for negative
server reply, or I<undef> in case of some error.

=cut

sub set {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        return $self->{_xs}->set(\@_)->[0];
    } else {
        $self->{_xs}->set(\@_);
    }
}


=item C<set_multi>

  $memd->set_multi(
      [$key, $value],
      [$key, $value, $expiration_time],
      ...
  );

Like L</set>, but operates on more than one key.  Takes the list of
array references each holding I<$key>, I<$value> and optional
I<$expiration_time>.

Note that multi commands are not all-or-nothing, some operations may
succeed, while others may fail.

I<Return:> in list context returns the list of results, each
I<$list[$index]> is the result value corresponding to the argument at
position I<$index>.  In scalar context, hash reference is returned,
where I<$href-E<gt>{$key}> hols the result value.  See L</set> to
learn what the result value is.

=cut

sub set_multi {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        if (wantarray) {
            return @{$self->{_xs}->set(@_)};
        } else {
            my @keys = map { $_->[0] } @_;
            my $results = $self->{_xs}->set(@_);
            return Cache::Memcached::Fast::_xs::_rvav2rvhv(\@keys, $results);
        }
    } else {
        $self->{_xs}->set(@_);
    }
}


=item C<cas>

  $memd->cas($key, $cas, $value);
  $memd->cas($key, $cas, $value, $expiration_time);

Store the I<$value> on the server under the I<$key>, but only if CAS
(I<Consistent Access Storage>) value associated with this key is equal
to I<$cas>.  I<$cas> is an opaque object returned with L</gets> or
L</gets_multi>.

See L</set> for I<$key>, I<$value>, I<$expiration_time> parameters
description.

I<Return:> boolean, true for positive server reply, false for negative
server reply, or I<undef> in case of some error.  Thus if the key
exists on the server, false would mean that some other client has
updated the value, and L</gets>, L</cas> command sequence should be
repeated.

B<cas> command first appeared in B<memcached> 1.2.4.

=cut

sub cas {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        return $self->{_xs}->cas(\@_)->[0];
    } else {
        $self->{_xs}->cas(\@_);
    }
}


=item C<cas_multi>

  $memd->cas_multi(
      [$key, $cas, $value],
      [$key, $cas, $value, $expiration_time],
      ...
  );

Like L</cas>, but operates on more than one key.  Takes the list of
array references each holding I<$key>, I<$cas>, I<$value> and optional
I<$expiration_time>.

Note that multi commands are not all-or-nothing, some operations may
succeed, while others may fail.

I<Return:> in list context returns the list of results, each
I<$list[$index]> is the result value corresponding to the argument at
position I<$index>.  In scalar context, hash reference is returned,
where I<$href-E<gt>{$key}> hols the result value.  See L</cas> to
learn what the result value is.

B<cas> command first appeared in B<memcached> 1.2.4.

=cut

sub cas_multi {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        if (wantarray) {
            return @{$self->{_xs}->cas(@_)};
        } else {
            my @keys = map { $_->[0] } @_;
            my $results = $self->{_xs}->cas(@_);
            return Cache::Memcached::Fast::_xs::_rvav2rvhv(\@keys, $results);
        }
    } else {
        $self->{_xs}->cas(@_);
    }
}


=item C<add>

  $memd->add($key, $value);
  $memd->add($key, $value, $expiration_time);

Store the I<$value> on the server under the I<$key>, but only if the
key B<doesn't> exists on the server.

See L</set> for I<$key>, I<$value>, I<$expiration_time> parameters
description.

I<Return:> boolean, true for positive server reply, false for negative
server reply, or I<undef> in case of some error.

=cut

sub add {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        return $self->{_xs}->add(\@_)->[0];
    } else {
        $self->{_xs}->add(\@_);
    }
}


=item C<add_multi>

  $memd->add_multi(
      [$key, $value],
      [$key, $value, $expiration_time],
      ...
  );

Like L</add>, but operates on more than one key.  Takes the list of
array references each holding I<$key>, I<$value> and optional
I<$expiration_time>.

Note that multi commands are not all-or-nothing, some operations may
succeed, while others may fail.

I<Return:> in list context returns the list of results, each
I<$list[$index]> is the result value corresponding to the argument at
position I<$index>.  In scalar context, hash reference is returned,
where I<$href-E<gt>{$key}> hols the result value.  See L</add> to
learn what the result value is.

=cut

sub add_multi {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        if (wantarray) {
            return @{$self->{_xs}->add(@_)};
        } else {
            my @keys = map { $_->[0] } @_;
            my $results = $self->{_xs}->add(@_);
            return Cache::Memcached::Fast::_xs::_rvav2rvhv(\@keys, $results);
        }
    } else {
        $self->{_xs}->add(@_);
    }
}


=item C<replace>

 $memd->replace($key, $value);
 $memd->replace($key, $value, $expiration_time);

Store the I<$value> on the server under the I<$key>, but only if the
key B<does> exists on the server.

See L</set> for I<$key>, I<$value>, I<$expiration_time> parameters
description.

I<Return:> boolean, true for positive server reply, false for negative
server reply, or I<undef> in case of some error.

=cut

sub replace {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        return $self->{_xs}->replace(\@_)->[0];
    } else {
        $self->{_xs}->replace(\@_);
    }
}


=item C<replace_multi>

  $memd->replace_multi(
      [$key, $value],
      [$key, $value, $expiration_time],
      ...
  );

Like L</replace>, but operates on more than one key.  Takes the list
of array references each holding I<$key>, I<$value> and optional
I<$expiration_time>.

Note that multi commands are not all-or-nothing, some operations may
succeed, while others may fail.

I<Return:> in list context returns the list of results, each
I<$list[$index]> is the result value corresponding to the argument at
position I<$index>.  In scalar context, hash reference is returned,
where I<$href-E<gt>{$key}> hols the result value.  See L</replace> to
learn what the result value is.

=cut

sub replace_multi {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        if (wantarray) {
            return @{$self->{_xs}->replace(@_)};
        } else {
            my @keys = map { $_->[0] } @_;
            my $results = $self->{_xs}->replace(@_);
            return Cache::Memcached::Fast::_xs::_rvav2rvhv(\@keys, $results);
        }
    } else {
        $self->{_xs}->replace(@_);
    }
}


=item C<append>

  $memd->append($key, $value);

B<Append> the I<$value> to the current value on the server under the
I<$key>.

I<$key> and I<$value> should be scalars, as well as current value on
the server.  C<append> doesn't affect expiration time of the value.

I<Return:> boolean, true for positive server reply, false for negative
server reply, or I<undef> in case of some error.

B<append> command first appeared in B<memcached> 1.2.4.

=cut

sub append {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        return $self->{_xs}->append(\@_)->[0];
    } else {
        $self->{_xs}->append(\@_);
    }
}


=item C<append_multi>

  $memd->append_multi(
      [$key, $value],
      ...
  );

Like L</append>, but operates on more than one key.  Takes the list of
array references each holding I<$key>, I<$value>.

Note that multi commands are not all-or-nothing, some operations may
succeed, while others may fail.

I<Return:> in list context returns the list of results, each
I<$list[$index]> is the result value corresponding to the argument at
position I<$index>.  In scalar context, hash reference is returned,
where I<$href-E<gt>{$key}> hols the result value.  See L</append> to
learn what the result value is.

B<append> command first appeared in B<memcached> 1.2.4.

=cut

sub append_multi {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        if (wantarray) {
            return @{$self->{_xs}->append(@_)};
        } else {
            my @keys = map { $_->[0] } @_;
            my $results = $self->{_xs}->append(@_);
            return Cache::Memcached::Fast::_xs::_rvav2rvhv(\@keys, $results);
        }
    } else {
        $self->{_xs}->append(@_);
    }
}


=item C<prepend>

  $memd->prepend($key, $value);

B<Prepend> the I<$value> to the current value on the server under the
I<$key>.

I<$key> and I<$value> should be scalars, as well as current value on
the server.  C<prepend> doesn't affect expiration time of the value.

I<Return:> boolean, true for positive server reply, false for negative
server reply, or I<undef> in case of some error.

B<prepend> command first appeared in B<memcached> 1.2.4.

=cut

sub prepend {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        return $self->{_xs}->prepend(\@_)->[0];
    } else {
        $self->{_xs}->prepend(\@_);
    }
}


=item C<prepend_multi>

  $memd->prepend_multi(
      [$key, $value],
      ...
  );

Like L</prepend>, but operates on more than one key.  Takes the list of
array references each holding I<$key>, I<$value>.

Note that multi commands are not all-or-nothing, some operations may
succeed, while others may fail.

I<Return:> in list context returns the list of results, each
I<$list[$index]> is the result value corresponding to the argument at
position I<$index>.  In scalar context, hash reference is returned,
where I<$href-E<gt>{$key}> hols the result value.  See L</prepend> to
learn what the result value is.

B<prepend> command first appeared in B<memcached> 1.2.4.

=cut

sub prepend_multi {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        if (wantarray) {
            return @{$self->{_xs}->prepend(@_)};
        } else {
            my @keys = map { $_->[0] } @_;
            my $results = $self->{_xs}->prepend(@_);
            return Cache::Memcached::Fast::_xs::_rvav2rvhv(\@keys, $results);
        }
    } else {
        $self->{_xs}->prepend(@_);
    }
}


=item C<get>

  $memd->get($key);

Retrieve the value for a I<$key>.  I<$key> should be a scalar.

I<Return:> value associated with the I<$key>, or nothing.

=cut

sub get {
    my Cache::Memcached::Fast $self = shift;
    return $self->{_xs}->get(@_);
}


=item C<get_multi>

  $memd->get_multi(@keys);

Retrieve several values associated with I<@keys>.  I<@keys> should be
an array of scalars.

I<Return:> reference to hash, where I<$href-E<gt>{$key}> holds
corresponding value.

=cut

sub get_multi {
    my Cache::Memcached::Fast $self = shift;
    return $self->{_xs}->get_multi(@_);
}


=item C<gets>

  $memd->gets($key);

Retrieve the value and its CAS for a I<$key>.  I<$key> should be a
scalar.

I<Return:> reference to an array I<[$cas, $value]>, or nothing.  You
may conveniently pass it back to L</cas> with I<@$res>:

  my $cas_val = $memd->gets($key);
  # Update value.
  if (defined $cas_val) {
      $$cas_val[1] = 3;
      $memd->cas($key, @$cas_val);
  }

B<gets> command first appeared in B<memcached> 1.2.4.

=cut

sub gets {
    my Cache::Memcached::Fast $self = shift;
    return $self->{_xs}->gets(@_);
}


=item C<gets_multi>

  $memd->gets_multi(@keys);

Retrieve several values and their CASs associated with I<@keys>.
I<@keys> should be an array of scalars.

I<Return:> reference to hash, where I<$href-E<gt>{$key}> holds a
reference to an array I<[$cas, $value]>.  Compare with L</gets>.

B<gets> command first appeared in B<memcached> 1.2.4.

=cut

sub gets_multi {
    my Cache::Memcached::Fast $self = shift;
    return $self->{_xs}->gets_multi(@_);
}


=item C<incr>

  $memd->incr($key);
  $memd->incr($key, $increment);

Increment the value for the I<$key>.  If current value is not a
number, zero is assumed.  An optional I<$increment> should be a
positive integer, when not given 1 is assumed.  Note that the server
doesn't check for overflow.

I<Return:> unsigned integer, new value for the I<$key>, or false for
negative server reply, or I<undef> in case of some error.

=cut

sub incr {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        return $self->{_xs}->incr(\@_)->[0];
    } else {
        $self->{_xs}->incr(\@_);
    }
}


=item C<incr_multi>

  $memd->incr_multi(
      @keys,
      [$key],
      [$key, $increment],
      ...
  );

Like L</incr>, but operates on more than one key.  Takes the list of
keys and array references each holding I<$key> and optional
I<$increment>.

Note that multi commands are not all-or-nothing, some operations may
succeed, while others may fail.

I<Return:> in list context returns the list of results, each
I<$list[$index]> is the result value corresponding to the argument at
position I<$index>.  In scalar context, hash reference is returned,
where I<$href-E<gt>{$key}> hols the result value.  See L</incr> to
learn what the result value is.

=cut

sub incr_multi {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        if (wantarray) {
            return @{$self->{_xs}->incr(@_)};
        } else {
            my @keys = map { $_->[0] } @_;
            my $results = $self->{_xs}->incr(@_);
            return Cache::Memcached::Fast::_xs::_rvav2rvhv(\@keys, $results);
        }
    } else {
        $self->{_xs}->incr(@_);
    }
}


=item C<decr>

  $memd->decr($key);
  $memd->decr($key, $decrement);

Decrement the value for the I<$key>.  If current value is not a
number, zero is assumed.  An optional I<$decrement> should be a
positive integer, when not given 1 is assumed.  Note that the server
I<does> check for underflow, attempt to decrement the value below zero
would set the value to zero.  Similar to L<DBI|DBI>, zero is returned
as "0E0", and evaluates to true in a boolean context.

I<Return:> unsigned integer, new value for the I<$key>, or false for
negative server reply, or I<undef> in case of some error.

=cut

sub decr {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        return $self->{_xs}->decr(\@_)->[0];
    } else {
        $self->{_xs}->decr(\@_);
    }
}


=item C<decr_multi>

  $memd->decr_multi(
      @keys,
      [$key],
      [$key, $decrement],
      ...
  );

Like L</decr>, but operates on more than one key.  Takes the list of
keys and array references each holding I<$key> and optional
I<$decrement>.

Note that multi commands are not all-or-nothing, some operations may
succeed, while others may fail.

I<Return:> in list context returns the list of results, each
I<$list[$index]> is the result value corresponding to the argument at
position I<$index>.  In scalar context, hash reference is returned,
where I<$href-E<gt>{$key}> hols the result value.  See L</decr> to
learn what the result value is.

=cut

sub decr_multi {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        if (wantarray) {
            return @{$self->{_xs}->decr(@_)};
        } else {
            my @keys = map { $_->[0] } @_;
            my $results = $self->{_xs}->decr(@_);
            return Cache::Memcached::Fast::_xs::_rvav2rvhv(\@keys, $results);
        }
    } else {
        $self->{_xs}->decr(@_);
    }
}


=item C<delete>

  $memd->delete($key);
  $memd->delete($key, $delay);

Delete I<$key> and its value from the cache.  I<$delay> is an optional
non-negative integer number of seconds to delay the operation.  During
this time L</add> and L</replace> commands will be rejected by the
server.  When omitted, zero is assumed, i.e. delete immediately.

I<Return:> boolean, true for positive server reply, false for negative
server reply, or I<undef> in case of some error.

=cut

sub delete {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        return $self->{_xs}->delete(\@_)->[0];
    } else {
        $self->{_xs}->delete(\@_);
    }
}


=item C<remove> (B<deprecated>)

Alias for L</delete>, for compatibility with B<Cache::Memcached>.

=cut

*remove = \&delete;


=item C<delete_multi>

  $memd->delete_multi(
      @keys,
      [$key],
      [$key, $delay],
      ...
  );

Like L</delete>, but operates on more than one key.  Takes the list of
keys and array references each holding I<$key> and optional I<$delay>.

Note that multi commands are not all-or-nothing, some operations may
succeed, while others may fail.

I<Return:> in list context returns the list of results, each
I<$list[$index]> is the result value corresponding to the argument at
position I<$index>.  In scalar context, hash reference is returned,
where I<$href-E<gt>{$key}> hols the result value.  See L</delete> to
learn what the result value is.

=cut

sub delete_multi {
    my Cache::Memcached::Fast $self = shift;
    if (defined wantarray) {
        if (wantarray) {
            return @{$self->{_xs}->delete(@_)};
        } else {
            my @keys = map { $_->[0] } @_;
            my $results = $self->{_xs}->delete(@_);
            return Cache::Memcached::Fast::_xs::_rvav2rvhv(\@keys, $results);
        }
    } else {
        $self->{_xs}->delete(@_);
    }
}


=item C<flush_all>

  $memd->flush_all;
  $memd->flush_all($delay);

Flush all caches the client knows about.  I<$delay> is an optional
non-negative integer number of seconds to delay the operation.  The
delay will be distributed across the servers.  For instance, when you
have three servers, and call C<flush_all(30)>, the servers would get
30, 15, 0 seconds delays respectively.  When omitted, zero is assumed,
i.e. flush immediately.

I<Return:> reference to hash, where I<$href-E<gt>{$server}> holds
corresponding result value.  I<$server> is either I<host:port> or
F</path/to/unix.sock>, as described in L</servers>.  Result value is a
boolean, true for positive server reply, false for negative server
reply, or I<undef> in case of some error.

=cut

sub flush_all {
    my Cache::Memcached::Fast $self = shift;
    $self->{_xs}->flush_all(@_);
}


=item C<nowait_push>

  $memd->nowait_push;

Push all pending requests to the server(s), and wait for all replies.
When L</nowait> mode is enabled, the requests issued in a void context
may not reach the server(s) immediately (because the reply is not
waited for).  Instead they may stay in the send queue on the local
host, or in the receive queue on the remote host(s), for quite a long
time.  This method ensures that they are delivered to the server(s),
processed there, and the replies have arrived (or some error has
happened that caused some connection(s) to be closed).

Destructor will call this method to ensure that all requests are
processed before the connection is closed.

I<Return:> nothing.

=cut

sub nowait_push {
    my Cache::Memcached::Fast $self = shift;
    $self->{_xs}->nowait_push;
}


=item C<server_versions>

  $memd->server_versions;

Get server versions.

I<Return:> reference to hash, where I<$href-E<gt>{$server}> holds
corresponding server version.  I<$server> is either I<host:port> or
F</path/to/unix.sock>, as described in L</servers>.

=cut

sub server_versions {
    my Cache::Memcached::Fast $self = shift;
    $self->{_xs}->server_versions;
}


1;

__END__

=back


=head1 Compatibility with Cache::Memcached

This module is designed to be a drop in replacement for
L<Cache::Memcached|Cache::Memcached>.  Where constructor parameters
are the same as in Cache::Memcached, the default values are also the
same, and new parameters are disabled by default (the exception is
L</close_on_error>, which is absent in Cache::Memcached and enabled by
default in this module).  Internally Cache::Memcached::Fast uses the
same hash function as Cache::Memcached, and thus should distribute the
keys across several servers the same way.  So both modules may be used
interchangeably.  Most users of the original module should be able to
use this module after replacing I<"Cache::Memcached"> with
I<"Cache::Memcached::Fast">, without further code modifications.
However, as of this release, the following features of
Cache::Memcached are not supported by Cache::Memcached::Fast (and some
of them will never be):


=head2 Constructor parameters

=over

=item I<no_rehash>

Current implementation never rehashes keys, instead L</max_failures>
and L</failure_timeout> are used.

If the client would rehash the keys, a consistency problem would
arise: when the failure occurs the client can't tell whether the
server is down, or there's a (transient) network failure.  While some
clients might fail to reach a particular server, others may still
reach it, so some clients will start rehashing, while others will not,
and they will no longer agree which key goes where.


=item I<readonly>

Not supported.  Easy to add.  However I'm not sure about the demand
for it, and it will slow down things a bit (because from design point
of view it's better to add it on Perl side rather than on XS side).


=item I<debug>

Not supported.  Since the implementation is different, there can't be
any compatibility on I<debug> level.

=back


=head2 Methods

=over

=item Passing keys

Every key should be a scalar.  The syntax when key is a reference to
an array I<[$precomputed_hash, $key]> is not supported.


=item C<set_servers>

Not supported.  Server set should not change after client object
construction.


=item C<set_debug>

Not supported.  See L</debug>.


=item C<set_readonly>

Not supported.  See L</readonly>.


=item C<set_norehash>

Not supported.  See L</no_rehash>.


=item C<set_compress_threshold>

Not supported.  Easy to add.  Currently you specify
I<compress_threshold> during client object construction.


=item C<stats>

Not supported.  Perhaps will appear in the future releases.


=item C<disconnect_all>

Not supported.  Easy to add.  Meanwhile to disconnect from all servers
you may do

  undef $memd;

or 

  $memd = undef;

=back


=head1 Tainted data

In current implementation tainted flag is neither tested nor
preserved, storing tainted data and retrieving it back would clear
tainted flag.  See L<perlsec|perlsec>.


=head1 BUGS

Please report any bugs or feature requests to
C<bug-cache-memcached-fast at rt.cpan.org>, or through the web
interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Cache-Memcached-Fast>.
I will be notified, and then you'll automatically be notified of
progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Cache::Memcached::Fast


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Cache-Memcached-Fast>


=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Cache-Memcached-Fast>


=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Cache-Memcached-Fast>


=item * Search CPAN

L<http://search.cpan.org/dist/Cache-Memcached-Fast>


=back


=head1 SEE ALSO

L<Cache::Memcached|Cache::Memcached> - original pure Perl B<memcached>
client.

L<http://www.danga.com/memcached/> - B<memcached> website.


=head1 AUTHORS

Tomash Brechko, C<< <tomash.brechko at gmail.com> >> - design and
implementation.

Michael Monashev, C<< <postmaster at softsearch.ru> >> - project
management, design suggestions, testing.


=head1 ACKNOWLEDGEMENTS

Development of this module is sponsored by S<Monashev Co. Ltd.>

Thanks to Peter J. Holzer for enlightening on UTF-8 support.


=head1 WARRANTY

There's B<NONE>, neither explicit nor implied.  But you knew it already
;).


=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007-2008 Tomash Brechko.  All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
