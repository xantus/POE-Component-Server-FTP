package POE::Component::Server::FTP;

######################################################################
### POE::Component::Server::FTP
### L.M.Orchard ( deus_x@pobox.com )
### Modified by David Davis ( xantus@cpan.org )
###
### TODO:
###
### Copyright (c) 2001 Leslie Michael Orchard.  All Rights Reserved.
### This module is free software; you can redistribute it and/or
### modify it under the same terms as Perl itself.
###
### Changes Copyright (c) 2003 David Davis and Teknikill Software
######################################################################

use strict;
use warnings;

our @ISA = qw(Exporter);
our $VERSION = '0.03';

use Socket;
use Carp;
use POE qw(Session Wheel::ReadWrite Filter::Line
		   Driver::SysRW Wheel::SocketFactory);
use POE::Component::Server::FTP::ControlSession;
use POE::Component::Server::FTP::ControlFilter;

sub DEBUG { 0 }

sub spawn {
	my $package = shift;
	croak "$package requires an even number of parameters" if @_ % 2;
	my %params = @_;
	my $alias = $params{'Alias'};
	$alias = 'ftpd' unless defined($alias) and length($alias);

	my $listen_port = $params{listen_port} || 21;

	POE::Session->create(
		#options => {trace=>1},
		args => [ %params ],
		package_states => [
			'POE::Component::Server::FTP' => {
				_start       => '_start',
				_stop        => '_stop',
				accept       => 'accept',
				accept_error => 'accept_error',
				signals      => 'signals'
			}
		],
	);

	return 1;
}

sub _start {
	my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
	%{$heap->{params}} = splice @_,ARG0;

	$session->option( @{$heap->{params}{SessionOptions}} ) if $heap->{params}{SessionOptions};
	$kernel->alias_set($heap->{params}{alias});

	# watch for SIGINT
	$kernel->sig('INT', 'signals');

	# create a socket factory
	$heap->{wheel} = new POE::Wheel::SocketFactory(
		BindPort       => $heap->{params}{ListenPort},          # on this port
		Reuse          => 'yes',          # and allow immediate port reuse
		SuccessEvent   => 'accept',       # generating this event on connection
		FailureEvent   => 'accept_error'  # generating this event on error
	);
	DEBUG && print "Listening to port $heap->{params}{ListenPort} on all interfaces.\n";
}

sub _stop {
	DEBUG && print "Server stopped.\n";
}

# Accept a new connection

sub accept {
	my ($heap, $accepted_handle, $peer_addr, $peer_port) = @_[HEAP, ARG0, ARG1, ARG2];

	$peer_addr = inet_ntoa($peer_addr);
	my $ip = getsockname($accepted_handle);
	DEBUG && print "Server received connection on $ip from $peer_addr : $peer_port\n";

	my $opt = { %{$heap->{params}} };
	$opt->{Handle} = $accepted_handle;
	$opt->{ListenIP} = $ip;
	$opt->{PeerAddr} = $peer_addr;
	$opt->{PeerPort} = $peer_port;
	POE::Component::Server::FTP::ControlSession->new($opt);
}

# Handle an error in connection acceptance

sub accept_error {
	my ($operation, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
	DEBUG && print "Server encountered $operation error $errnum: $errstr\n";
}

# Handle incoming signals (INT)

sub signals {
	my $signal_name = $_[ARG0];

	DEBUG && print "Server caught SIG$signal_name\n";
	# do not handle the signal
	return 0;
}

1;
__END__

=head1 NAME

POE::Component::Server::FTP - Event-based FTP server on a virtual filesystem

=head1 SYNOPSIS

  use POE qw(Wheel::ReadWrite Driver::SysRW
	    	   Wheel::SocketFactory Component::Server::FTP);

  POE::Component::Server::FTP->spawn
    (
     Alias           => 'ftpd',
     ListenPort      => 2112,
     FilesystemClass => 'Filesys::Virtual::Plain',
     FilesystemArgs  =>
     {
	  'root_path' => '/',      # This is actual root for all paths
	  'cwd'       => '/',      # Initial current working dir
	  'home_path' => '/Users', # Home directory for '~'
     }
    );

  $poe_kernel->run();

=head1 DESCRIPTION

POE::Component::Server::FTP is an event driven FTP server backed by a
virtual filesystem interface as implemented by Filesys::Virtual.

=head1 AUTHORS

L.M.Orchard, deus_x@pobox.com
David Davis, xantus@cpan.org

=head1 SEE ALSO

perl(1), Filesys::Virtual.

=cut
