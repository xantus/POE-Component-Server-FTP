package POE::Component::Server::FTP;

###########################################################################
### POE::Component::Server::FTP
### L.M.Orchard (deus_x@pobox.com)
### David Davis (xantus@cpan.org)
###
### TODO:
###
### Copyright (c) 2001 Leslie Michael Orchard.  All Rights Reserved.
### This module is free software; you can redistribute it and/or
### modify it under the same terms as Perl itself.
###
### Changes Copyright (c) 2003-2004 David Davis and Teknikill Software
###########################################################################

use strict;
use warnings;

our @ISA = qw(Exporter);
our $VERSION = '0.04';

use Socket;
use Carp;
use POE qw(Session Wheel::ReadWrite Filter::Line
		   Driver::SysRW Wheel::SocketFactory
		   Wheel::Run Filter::Reference);
use POE::Component::Server::FTP::ControlSession;
use POE::Component::Server::FTP::ControlFilter;

sub spawn {
	my $package = shift;
	croak "$package requires an even number of parameters" if @_ % 2;
	my %params = @_;
	my $alias = $params{'Alias'};
	$alias = 'ftpd' unless defined($alias) and length($alias);
	$params{'Alias'} = $alias;
	$params{'ListenPort'} = $params{'ListenPort'} || 21;
	$params{'TimeOut'} = $params{'TimeOut'} || 0;
	$params{'DownloadLimit'} = $params{'DownloadLimit'} || 0;
	$params{'UploadLimit'} = $params{'UploadLimit'} || 0;
	$params{'LimitSceme'} = $params{'LimitSceme'} || 'none';

	POE::Session->create(
		#options => {trace=>1},
		args => [ \%params ],
		package_states => [
			'POE::Component::Server::FTP' => {
				_start			=> '_start',
				_stop			=> '_stop',
				_write_log		=> '_write_log',
				accept			=> 'accept',
				accept_error	=> 'accept_error',
				signals			=> 'signals',
				_bw_limit		=> '_bw_limit',
				_dcon_cleanup	=> '_dcon_cleanup',
				cmd_stdout		=> 'cmd_stdout',
				cmd_stderr		=> 'cmd_stderr',
				cmd_error		=> 'cmd_error',
			}
		],
	);

	return 1;
}

sub _start {
	my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
	%{$heap->{params}} = %{ $_[ARG0] };
	
	$heap->{_main_pid} = $$;
	
	$session->option( @{$heap->{params}{'SessionOptions'}} ) if $heap->{params}{'SessionOptions'};
	$kernel->alias_set($heap->{params}{'Alias'});

	# watch for SIGINT
	$kernel->sig('INT', 'signals');

	# create a socket factory
	$heap->{wheel} = POE::Wheel::SocketFactory->new(
		BindPort       => $heap->{params}{ListenPort},          # on this port
		Reuse          => 'yes',          # and allow immediate port reuse
		SuccessEvent   => 'accept',       # generating this event on connection
		FailureEvent   => 'accept_error'  # generating this event on error
	);
	
	$kernel->call($session->ID => _write_log => { v => 2, msg => "Listening to port $heap->{params}{ListenPort} on all interfaces." });
}

sub _stop {
	my ($kernel, $session) = @_[KERNEL, SESSION];
	$kernel->call($session->ID => _write_log => { v => 2, msg => "Server stopped." });
}

# Accept a new connection

sub accept {
	my ($kernel, $heap, $session, $accepted_handle, $peer_addr, $peer_port) = @_[KERNEL, HEAP, SESSION, ARG0, ARG1, ARG2];

	$peer_addr = inet_ntoa($peer_addr);
	my $ip = inet_ntoa((sockaddr_in(getsockname($accepted_handle)))[1]);
	my $listen_ip = (defined $heap->{params}{FirewallIP}) ? $heap->{params}{FirewallIP} : $ip;
	 
	$kernel->call($session->ID => _write_log => { v => 2, msg => "Server received connection on $listen_ip from $peer_addr : $peer_port" });

	my $opt = { %{$heap->{params}} };
	$opt->{Handle} = $accepted_handle;
	$opt->{ListenIP} = $ip;
	$opt->{PeerAddr} = $peer_addr;
	$opt->{PeerPort} = $peer_port;

	POE::Component::Server::FTP::ControlSession->new($opt);
	
#	$heap->{control_session} = POE::Wheel::Run->new(
#		Program     => sub {
#			my $raw;
#			my $size   = 4096;
#			#my $filter = POE::Filter::Reference->new();
#			my $filter = POE::Filter::Line->new();
#			
#			POE::Component::Server::FTP::ControlSession->new($opt);
#			
#			#
#			# POE::Filter::Reference does buffering so that you don't have to.
#			#
#			READ: while (sysread( STDIN, $raw, $size )) {
#				my $s = $filter->get( [$raw] );
#				
#				#
#				# It is possible that $filter->get() has returned more than one
#				# structure from the parent process.  Each $t represents whatever
#				# was pushed from the parent.
#				#
#				foreach my $t (@$s) {
#					print "-$t\n";
#					#
#					# Here is a stand-in for something that might be doing
#					# real work.
#					#
#					#$t->{fubar} = 'mycmd';
#					
#					#
#					# this part re-freezes the data structure and writes
#					# it back to the parent process.
#					#
#					#my $u = $filter->put( [$t] );
#					#print STDOUT @$u;
#					
#					#
#					# this is the exit condition.
#					#
#					last READ if ( $t->{'cmd'} eq 'shutdown' );
#				}	
#			}
#		},
#		ErrorEvent  => 'cmd_error',
#		StdoutEvent => 'cmd_stdout',
#		StderrEvent => 'cmd_stderr',
#		StdinFilter => POE::Filter::Line->new(),
#		#StdioFilter => POE::Filter::Reference->new(),
#		#StdinFilter => POE::Filter::Reference->new(),
#	) or die "$0: can't POE::Wheel::Run->new";
}

sub _bw_limit {
    my ($kernel, $heap, $session, $sender, $type, $ip, $bps) = @_[KERNEL, HEAP, SESSION, SENDER, ARG0, ARG1, ARG2];
	$heap->{$type}{$ip}{$sender->ID} = $bps;
	my $num = scalar(keys %{$heap->{$type}{$ip}});
	my $newlimit = ((($type eq 'dl') ? $heap->{params}{'DownloadLimit'} : $heap->{params}{'UploadLimit'}) / $num);
	return ($bps > $newlimit) ? 1 : 0;
}

sub _dcon_cleanup {
    my ($kernel, $heap, $session, $type, $ip, $sid) = @_[KERNEL, HEAP, SESSION, ARG0, ARG1, ARG2];
	$kernel->call($session->ID => _write_log => { v => 4, msg => "cleaing up $type limiter for $ip ($sid)" });
	delete $heap->{$type}{$ip}{$sid};
}

sub cmd_error {
    my ( $heap, $op, $code, $handle ) = @_[ HEAP, ARG0, ARG1, ARG4 ];

    if ( $op eq 'read' and $code == 0 and $handle eq 'STDOUT' ) {
        warn "child has closed output";
        delete $heap->{control_session};
    }
}

#
# demonstrate that something is happening.
#
sub cmd_stdout {
    my ( $heap, $txt ) = @_[ HEAP, ARG0 ];

    print STDERR join ":", 'cmd_stdout ', $txt, "\n";

}

#
# Just so that we can see what the child writes on errors.
#
sub cmd_stderr {
    my ( $heap, $txt ) = @_[ HEAP, ARG0 ];
    print STDERR "cmd_stderr: $txt\n";
}

# Handle an error in connection acceptance

sub accept_error {
	my ($kernel, $session, $operation, $errnum, $errstr) = @_[KERNEL, SESSION, ARG0, ARG1, ARG2];
	$kernel->call($session->ID => write_log => { v => 1, msg => "Server encountered $operation error $errnum: $errstr" });
}

# Handle incoming signals (INT)

sub signals {
	my ($kernel, $session, $signal_name) = @_[KERNEL, SESSION, ARG0];

	$kernel->call($session->ID => _write_log => { v => 1, msg => "Server caught SIG$signal_name" });

	# to stop ctrl-c / INT
	if ($signal_name eq 'INT') {
		#$_[KERNEL]->sig_handled();
	}
	
	return 0;
}

sub _write_log {
	my ($kernel, $session, $heap, $sender, $o) = @_[KERNEL, SESSION, HEAP, SENDER, ARG0];
	if ($o->{v} <= $heap->{params}{'LogLevel'}) {
		my $datetime = localtime();
		my $sender = (defined $o->{sid}) ? $o->{sid} : $sender->ID;
		my $type = (defined $o->{type}) ? $o->{type} : 'M';
		print STDERR "[$datetime][$type$sender] $o->{msg}\n";
	}
}


1;
__END__

=head1 NAME

POE::Component::Server::FTP - Event-based FTP server on a virtual filesystem

=head1 SYNOPSIS

	use POE qw(Component::Server::FTP);
	use Filesys::Virtual;

	POE::Component::Server::FTP->spawn(
		Alias           => 'ftpd',				# ftpd is default
		ListenPort      => 2112,				# port to listen on
		Domain			=> 'blah.net',			# domain shown on connection
		Version			=> 'ftpd v1.0',			# shown on connection, you can mimic...
		AnonymousLogin	=> 'allow',				# deny, allow
		FilesystemClass => 'Filesys::Virtual::Plain', # Currently the only one available
		FilesystemArgs  => {
			'root_path' => '/',					# This is actual root for all paths
			'cwd'       => '/',					# Initial current working dir
			'home_path' => '/home',				# Home directory for '~'
		},
		# use 0 to disable these Limits
		DownloadLimit	=> (50 * 1024),			# 50 kb/s per ip/connection (use LimitSceme to configure)
		UploadLimit		=> (100 * 1024),		# 100 kb/s per ip/connection (use LimitSceme to configure)
		LimitSceme		=> 'ip',				# ip or per (connection)
		
		LogLevel		=> 4,					# 4=debug, 3=less info, 2=quiet, 1=really quiet
		TimeOut			=> 120,					# Connection Timeout
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
