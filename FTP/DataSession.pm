package POE::Component::Server::FTP::DataSession;

######################################################################
### POE::Component::Server::FTP::DataSession
### L.M.Orchard ( deus_x@pobox.com )
### Modified by David Davis ( xantus@cpan.org )
###
### TODO:
### -- POEify the data channel
### -- Move file seeking to Filesys::Virtual
###
### Copyright (c) 2001 Leslie Michael Orchard.  All Rights Reserved.
### This module is free software; you can redistribute it and/or
### modify it under the same terms as Perl itself.
###
### Changes Copyright (c) 2003 David Davis and Teknikill Software
######################################################################

use strict;

use IO::Scalar;
use IO::Socket::INET;
use POE qw(Session Wheel::ReadWrite Filter::Stream Driver::SysRW Wheel::SocketFactory);

use Data::Dumper;

sub DEBUG { 0 }

# Create a new DataSession

sub new {
	my ($type, $opt) = @_;
	my $self = bless { }, $type;

	POE::Session->create(
		 #options =>{ trace=>1 },
		 args => [ $opt ],
		 object_states => [
			$self => {
				_start			=> '_start',
				_stop			=> '_stop',

				start_LIST		=> 'start_LIST',
				start_NLST		=> 'start_NLST',
				start_STOR		=> 'start_STOR',
				start_RETR		=> 'start_RETR',

				execute			=> 'execute',
				data_send		=> 'data_send',

				data_receive	=> 'data_receive',
				data_flushed	=> 'data_flushed',
				data_error		=> 'data_error',
				data_throttle	=> 'data_throttle',
				data_resume		=> 'data_resume',

				_sock_up		=> '_sock_up',
				_sock_down		=> '_sock_down',
			}
		],
	);

	undef;
}

sub _start {
	my ($kernel, $heap, $opt) = @_[KERNEL, HEAP, ARG0];

# generating a port num
#	my $x = pack('n',$port);
#	my $p1 = ord(substr($x,0,1));
#	my $p2 = ord(substr($x,1,1));

	$heap->{listening} = 0;

	if ($opt->{data_port}) {
		# PORT command
		my ($h1, $h2, $h3, $h4, $p1, $p2) = split(',', $opt->{data_port});

		my $peer_addr = $h1.".".$h2.".".$h3.".".$h4;
		$heap->{port} = ($p1<<8)+$p2;
		$heap->{remote_ip} = $peer_addr;

		$heap->{data} = POE::Wheel::SocketFactory->new(
			SocketDomain => AF_INET,
			SocketType => SOCK_STREAM,
			SocketProtocol => 'tcp',
			RemoteAddress => $peer_addr,
			RemotePort => $heap->{port},
			SuccessEvent => '_sock_up',
			FailureEvent => '_sock_down',
		);

		$heap->{cmd} = $opt->{cmd};
		$heap->{rest} = $opt->{rest};
	} else {
		# PASV command
		$heap->{port} = ($opt->{port1}<<8)+$opt->{port2};
		
		$heap->{data} = POE::Wheel::SocketFactory->new(
			BindAddress    => INADDR_ANY, # Sets the bind() address
			BindPort       => $heap->{port}, # Sets the bind() port
			SuccessEvent   => '_sock_up', # Event to emit upon accept()
			FailureEvent   => '_sock_down', # Event to emit upon error
			SocketDomain   => AF_INET, # Sets the socket() domain
			SocketType     => SOCK_STREAM, # Sets the socket() type
			SocketProtocol => 'tcp', # Sets the socket() protocol
			Reuse          => 'on', # Lets the port be reused
		);

		$heap->{listening} = 1;
		# the command is issued on the next call via
		# a direct post to our session
	}
	
	$heap->{filesystem} = $opt->{fs};
	$heap->{block_size} = 8 * 1024;
	$heap->{opt} = $opt->{opt};
}

sub _sock_up {
	my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

	my $buffer_max = 8 * 1024;
	my $buffer_min = 128;

	$heap->{data} = new POE::Wheel::ReadWrite(
		Handle			=> $socket,
		Driver			=> POE::Driver::SysRW->new(),
		Filter			=> POE::Filter::Stream->new(),
		InputEvent		=> 'data_receive',
		ErrorEvent		=> 'data_error',
		FlushedEvent	=> 'data_flushed',
		HighMark		=> $buffer_max,
		LowMark			=> $buffer_min,
		HighEvent		=> 'data_throttle',
		LowEvent		=> 'data_resume',
	);
	# remote_ip??

	if ($heap->{listening} == 0) {
		DEBUG && print "Data session started for $heap->{cmd}($heap->{opt})\n";
		$kernel->yield('start_'.(uc $heap->{cmd}), $heap->{opt});
	} else {
		DEBUG && print "Received connection from $heap->{remote_ip}\n";
	}
}

sub _sock_down {
	DEBUG && print "socket down\n";
	delete $_[HEAP]->{data};
}

sub start_PASV {
	my ($kernel, $heap, $dirfile) = @_[KERNEL, HEAP, ARG0];
	my $fs = $heap->{filesystem};

}

sub start_LIST {
	my ($kernel, $heap, $dirfile) = @_[KERNEL, HEAP, ARG0];
	my $fs = $heap->{filesystem};

	my $out = "";
	foreach ($fs->list_details($dirfile)) {
		$out .= "$_\r\n";
	}

	$heap->{input_fh} = IO::Scalar->new(\$out);
	$heap->{send_done} = 0;
	$heap->{send_okay} = 1;
}

sub start_NLST {
	my ($kernel, $heap, $dirfile) = @_[KERNEL, HEAP, ARG0];
	my $fs = $heap->{filesystem};

	my $out = "";
	foreach ($fs->list($dirfile)) {
		$out .= "$_\r\n";
	}

	$heap->{input_fh} = IO::Scalar->new(\$out);
	$heap->{send_done} = 0;
	$heap->{send_okay} = 1;
}

sub start_RETR {
	my ($kernel, $heap, $fh, $rest) = @_[KERNEL, HEAP, ARG0, ARG1];

	if (defined $rest) {
		$heap->{rest} = $rest;
	}
	
	$heap->{input_fh} = $fh;
	DEBUG && print "Seeking to $heap->{rest}\n";
	seek($fh,$heap->{rest},0);
	
	$heap->{send_done} = 0;
	$heap->{send_okay} = 1;
}

sub start_STOR {
	my ($heap, $fh, $rest) = @_[HEAP, ARG0, ARG1];
	
	if (defined $rest) {
		$heap->{rest} = $rest;
	}
	
	$heap->{output_fh} = $fh;
	
	DEBUG && print "Seeking to $heap->{rest}\n";
	seek($fh,$heap->{rest},0);
}

sub _stop {
	my $heap = $_[HEAP];
	# uhhhh
}

# Execute the session's pending upload

sub execute {
	if (defined $_[HEAP]->{input_fh}) {
		$_[KERNEL]->yield('data_send');
	} elsif (!defined $_[HEAP]->{output_fh}) {
		if ($_[HEAP]->{listening} == 0) {
			delete $_[HEAP]->{data};
		}
	}
}

# Send a block to the remote client

sub data_send {
	my ($kernel, $session, $heap) =	@_[KERNEL, SESSION, HEAP];

	if ( (!defined $heap->{input_fh}) || (! ref $heap->{input_fh} ) ) {
		delete $heap->{data};
	} elsif ($heap->{send_okay} && (defined $heap->{data})) {
		### Read in a block from the file.
		my $buf;
		my $len = $heap->{input_fh}->read($buf, $heap->{block_size});

		### If something was read, queue it to be sent, and yield
		### back for another send_block.
		if ($len > 0) {
			$heap->{data}->put($buf);
			$kernel->yield('data_send');
		} else {
			# If nothing was read, assume EOF, and shut everything down.
			my $fs = $heap->{filesystem};
			$fs->close_read($heap->{input_fh});
			delete $heap->{input_fh};

			### Thanks, poe.perl.org!
			if ($heap->{data}->get_driver_out_octets() == 0) {
				delete $heap->{data};
			} else {
				$heap->{send_done} = 1;
			}
		}
	}
}

# Recieve a block from the remote client

sub data_receive {
	if ($_[HEAP]->{output_fh}) {
		$_[HEAP]->{output_fh}->print($_[ARG0]);
	} else {
		delete $_[HEAP]->{data};
	}
}

sub data_error {
	my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
	my $fs = $heap->{filesystem};

	if ($errnum) {
		DEBUG && print "Session with $heap->{remote_ip} : $heap->{port} ".
		"encountered $operation error $errnum: $errstr\n";
	} else {
		DEBUG && print "Client at $heap->{remote_ip} : $heap->{port} disconnected\n";
	}

	# either way, stop this session
	if (defined $heap->{output_fh}) {
		$fs->close_write($heap->{output_fh});
		delete $heap->{output_fh};
	}

	if (defined $heap->{input_fh}) {
		$fs->close_read($heap->{input_fh});
		delete $heap->{input_fh};
	}

	delete $heap->{data};
}

sub data_flushed {
	delete $_[HEAP]->{data} if ($_[HEAP]->{send_done});
}

sub data_throttle {
	$_[HEAP]->{okay_to_send} = 0;
}

sub data_resume {
	$_[HEAP]->{okay_to_send} = 1;
	$_[KERNEL]->yield('data_send');
}

1;
