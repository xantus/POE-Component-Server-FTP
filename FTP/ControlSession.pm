package POE::Component::Server::FTP::ControlSession;

###########################################################################
### POE::Component::Server::FTP::ControlSession
### L.M.Orchard (deus_x@pobox.com)
### David Davis (xantus@cpan.org)
###
### TODO:
### -- Better PASV port picking
### -- Support both ASCII and BINARY transfer types
### -- More logging!!
### -- MOTD after login
### -- MOTD before login (seperate)
###
### Copyright (c) 2001 Leslie Michael Orchard.  All Rights Reserved.
### This module is free software; you can redistribute it and/or
### modify it under the same terms as Perl itself.
###
### Changes Copyright (c) 2003-2004 David Davis and Teknikill Software
###########################################################################

use strict;

use POE qw(Session Wheel::ReadWrite Driver::SysRW Wheel::SocketFactory);
use POE::Component::Server::FTP::DataSession;
use POE::Component::Server::FTP::ControlFilter;

sub new {
	my $type = shift;
	my $opt = shift;

	my $self = bless { }, $type;

	POE::Session->create(
		#options => { default=>1, trace=>1 },
		args => [ $opt ],
		object_states => [
			$self => {
				_start		=> '_start',
				_stop		=> '_stop',
				_default	=> '_default',
				_child		=> '_child',
				_reset_timeout => '_reset_timeout',
				_write_log	=> '_write_log',
				time_out	=> 'time_out',
				receive		=> 'receive',
				flushed		=> 'flushed',
				error		=> 'error',
				signals		=> 'signals',

				QUIT		=> 'QUIT',
				USER		=> 'USER',
				PASS		=> 'PASS',
				TYPE		=> 'TYPE',
				SYST		=> 'SYST',
				MDTM		=> 'MDTM',
				CHMOD		=> 'CHMOD',
				DELE		=> 'DELE',
				MKD			=> 'MKD',
				RMD			=> 'RMD',
				CDUP		=> 'CDUP',
				CWD			=> 'CWD',
				PWD			=> 'PWD',
				NLST		=> 'NLST',
				LIST		=> 'LIST',
				PORT		=> 'PORT',
				RETR		=> 'RETR',
				STOR		=> 'STOR',
				PASV		=> 'PASV',
				NOOP		=> 'NOOP',
				REST		=> 'REST',
				ABOR		=> 'ABOR',
				APPE		=> 'APPE',
				SIZE		=> 'SIZE',
				
				SITE		=> 'SITE',

				# unimplemented
#				RNFR		=> 'RNFR',

				# rfc 0775 may not be fully supported...
				XMKD		=> 'XMKD',
				XRMD		=> 'XRMD',
				XPWD		=> 'PWD',
				XCUP		=> 'CDUP',
				XCWD		=> 'CWD',

				# rfc 737
				XSEN		=> 'XSEN',
			}
		],
	);

	return $self;
}

sub _start {
	my ($kernel, $heap, $session, $opt) = @_[KERNEL, HEAP, SESSION, ARG0];

	eval("use $opt->{FilesystemClass}");
	if ($@) {
		die "$@";
	}

	my $fs = ("$opt->{FilesystemClass}")->new($opt->{FilesystemArgs});

	# watch for SIGINT
	$kernel->sig('INT', 'signals');

	# start reading and writing
	$heap->{control} = POE::Wheel::ReadWrite->new(
		# on this handle
		Handle			=> $opt->{Handle}, 
		# using sysread and syswrite
		Driver			=> POE::Driver::SysRW->new(), 
		Filter			=> POE::Component::Server::FTP::ControlFilter->new(),
		# generating this event for requests
		InputEvent		=> 'receive',
		# generating this event for errors
		ErrorEvent		=> 'error',
		# generating this event for all-sent
		FlushedEvent	=> 'flushed',
	);

	$heap->{pasv} = 0;
	$heap->{auth} = 0;
	$heap->{rest} = 0;
	$heap->{host} = $opt->{PeerAddr};
	$heap->{port} = $opt->{PeerPort};
	$heap->{filesystem} = $fs;
	%{$heap->{params}} = %{ $opt };
	
	if ($heap->{params}{'TimeOut'} > 0) {
		$heap->{time_out} = $kernel->delay_set(time_out => $heap->{params}{'TimeOut'});
		$kernel->call($session->ID => _write_log => 4 => "Timeout set: id ".$heap->{time_out});
	}
	
	$kernel->call($session->ID => _write_log => 4 => "Control session started for $heap->{host} : $heap->{port}");

	$heap->{control}->put("220 $opt->{Domain} FTP server ($opt->{Version} ".localtime()." ready.)");
}

sub _stop {
	my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
	$kernel->call($session->ID => _write_log => 4 => "Client session ended with $heap->{host} : $heap->{port}");
}

sub _child {
	my ($kernel, $heap, $session, $action, $child) = @_[KERNEL, HEAP, SESSION, ARG0, ARG1];

	if ($action eq 'create') {
		$kernel->call($session->ID => _write_log => 4 => "child session created ".$child->ID);
		$heap->{pending_session} = $child;
	} elsif ($action eq 'lose') {
		$kernel->call($session->ID => _write_log => 3 => sprintf("Transfer complete %d kB/s of %d bytes",($child->get_heap->{bps}/1023),$child->get_heap->{total_bytes}));
		$kernel->call($session->ID => _write_log => 4 => "child session lost ".$child->ID);
		$kernel->call($session->ID => "_reset_timeout");
		if ($heap->{params}{'LimitSceme'} eq 'ip') {
			my $cheap = $child->get_heap;
			$kernel->call($heap->{params}{'Alias'} => _dcon_cleanup => $cheap->{type}, $cheap->{remote_ip} => $child->ID);
		}
		if (defined $heap->{abor}) {
			delete $heap->{abor};
		} else {
			$heap->{control}->put("226 Transfer complete.");
		}
		delete $heap->{pending_session};
	}
	
	return 0;
}

sub time_out {
	my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

	# if we have a child session, then there must be a transfer
	# going on, reset the timer
	if (defined $heap->{pending_session} &&
			$heap->{params}{'TimeOut'} > 0) {
		$heap->{time_out} = $kernel->delay_set(time_out => $heap->{params}{'TimeOut'});
		$kernel->call($session->ID => _write_log => 4 => "Timeout re-set: id ".$heap->{time_out});
		return;
	}
	
	unless ($heap->{control}) {
		$kernel->alarm_remove_all( );
		delete $heap->{control};
	}
	
	if ($heap->{auth} == 0) {
		$kernel->call($session->ID => _write_log => 2 => "Session ".$session->ID." timed out before login (".$heap->{params}{'TimeOut'}.")");
		$heap->{control}->put("421 Disconnecting you because you did't login before ".$heap->{params}{'TimeOut'}." seconds, Goodbye.");
	} else {
		$kernel->call($session->ID => _write_log => 2 => "Session ".$session->ID." timed out (".$heap->{params}{'TimeOut'}.")");
		$heap->{control}->put("421 Disconnecting you because you were inactive for ".$heap->{params}{'TimeOut'}." seconds, Goodbye.");
	}
	
	$kernel->alarm_remove_all( );
	delete $heap->{control};
}

sub receive {
	my ($kernel, $session, $heap, $cmd) = @_[KERNEL, SESSION, HEAP, ARG0];

	$kernel->call($session->ID => _write_log => 4 => "Received input from $heap->{host} : $heap->{port} -> $cmd->{cmd} (".join(',',@{$cmd->{args}}).")");

	if ($heap->{auth} == 1) {
		$kernel->call($session->ID => '_reset_timeout');
	}
	$kernel->post($session, $cmd->{cmd}, \@{$cmd->{args}});
}

sub error {
	my ($kernel, $heap, $session, $operation, $errnum, $errstr) = @_[KERNEL, HEAP, SESSION, ARG0, ARG1, ARG2];

	if ($errnum) {
		$kernel->call($session->ID => _write_log => 4 => "Session with $heap->{host} : $heap->{port} encountered $operation error $errnum: $errstr");
	} else {
		$kernel->call($session->ID => _write_log => 4 => "Client at $heap->{host} : $heap->{port} disconnected");
	}

	# either way, stop this session
	$kernel->alarm_remove_all( );
	delete $heap->{control};
}

sub flushed {
	my ($kernel, $heap) = @_[KERNEL, HEAP];
	
	if (defined $heap->{pending_session} && $heap->{listening} == 0) {
# this broke stuff, now execute is yielded another way
#		$kernel->post($heap->{pending_session}->ID, 'execute');
	}
}


sub signals {
	my ($kernel, $heap, $session, $signal_name) = @_[KERNEL, HEAP, SESSION, ARG0];
	
	$kernel->call($session->ID => _write_log => 4 => "Session with $heap->{host} : $heap->{port} caught SIG $signal_name");
	# do not handle the signal
	return 0;
}

sub SITE {
	my ($kernel, $heap, $session, $args) = @_[KERNEL, HEAP, SESSION, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $cmd = shift(@$args);
		$kernel->call($session->ID,$cmd,$args);
	}
}

sub NOOP {
	my ($kernel, $heap, $session, $args) = @_[KERNEL, HEAP, SESSION, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		# resetting the timeout is done in receive()
		$heap->{control}->put("200 No-op okay.");
	}
}

sub XSEN {
	my ($kernel, $heap, $session, $args) = @_[KERNEL, HEAP, SESSION, ARG0];
	
	# TODO send a message to the terminal
	#$args = join(' ',@$args);
	
	$heap->{control}->put("453 Not Allowed");
}

sub QUIT {
	my ($kernel, $heap, $session, $args) = @_[KERNEL, HEAP, SESSION, ARG0];

	$kernel->alarm_remove_all( );
	$heap->{control}->put("221 Goodbye.");
	delete $heap->{control};
}

sub USER {
	my ($kernel, $session, $heap, $username) = @_[KERNEL, SESSION, HEAP, ARG0];

	$username = join(' ',@$username);
	$heap->{username} = $username;

	if ($username eq "anonymous") {
		$heap->{control}->put("331 Guest login ok, send your complete ".
							  "e-mail address as password.");
	} else {
		$heap->{control}->put("331 Password required for $username");
	}
}

sub PASS {
	my ($kernel, $session, $heap, $password) = @_[KERNEL, SESSION, HEAP, ARG0];

	$password = join(' ',@$password);
	my @list;
	my $fs = $heap->{filesystem};

	if (exists($heap->{username})) {
		if ($heap->{params}{AnonymousLogin} eq 'deny' && $heap->{username} eq 'anonymous') {
			$kernel->call($session->ID => _write_log => 1 => "Anonymous login denied.");
			$heap->{control}->put("530 Login incorrect.");
			$heap->{auth} = 0;
			return;
		}
		if ($fs->login($heap->{username}, $password)) {
			$kernel->call($session->ID => _write_log => 1 => "User $heap->{username} logged in.");
			# MOTD?
			$heap->{control}->put("230 Logged in.");
			$heap->{auth} = 1;
			$kernel->call($session->ID => "_reset_timeout");
		} else {
			$kernel->call($session->ID => _write_log => 1 => "Incorrect login");
			$heap->{control}->put("530 Login incorrect.");
			$heap->{auth} = 0;
		}
	} else {
		$heap->{control}->put("503 Login with USER first.");
	}
}

# Not implemented.
sub REST {
	my ($kernel, $session, $heap, $args) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	if ($args->[0] =~ m/^\d+$/) {
		$heap->{rest} = $args->[0];
		$heap->{control}->put("350 Will attempt to restart at postion $args->[0].");
	} else {
		
	}
}

# Not implemented.
sub TYPE {
	my ($kernel, $session, $heap, $type) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$type = $type->[0];
		
	$heap->{control}->put("200 Type set to I.");
}

# Not implemented.
sub SYST {
	my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$heap->{control}->put("215 UNIX Type: L8");
}

sub ABOR {
	my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	if (defined $heap->{pending_session}) {
		$kernel->post($heap->{pending_session}->ID => 'data_throttle');
		$kernel->post($heap->{pending_session}->ID => '_drop');
		$heap->{abor} = 1;
	}
	
	$heap->{control}->put("200 ABOR successfull");
	# TODO what do i send?
}

sub MDTM {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$fn = join(' ',@$fn);
	my $fs = $heap->{filesystem};
	my @modtime = $fs->modtime($fs);
	if ($modtime[0] == 0) {
		$heap->{control}->put("550 MDTM $fn: Permission denied.");
	} else {
		$heap->{control}->put("213 ".$modtime[1]);
	}
}

sub SIZE {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$fn = join(' ',@$fn);
	my $fs = $heap->{filesystem};
	my $size = $fs->size($fs);
	$heap->{control}->put("213 ".$size);
	
#	my @modtime = $fs->modtime($fs);
#	if ($modtime[0] == 0) {
#		$heap->{control}->put("550 SIZE $fn: Permission denied.");
#	} else {
#		$heap->{control}->put("213 ".$modtime[1]);
#	}
}

sub CHMOD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	my $mode = shift(@$fn);
	$fn = join(' ',@$fn);
	my $fs = $heap->{filesystem};

	if ($fs->chmod($mode, $fn)) {
		$heap->{control}->put("200 CHMOD command successful.");
	} else {
		$heap->{control}->put("550 CHMOD command unsuccessful");
	}
}

sub DELE {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$fn = join(' ',@$fn);
	my $fs = $heap->{filesystem};

	if ($fs->delete($fn)) {
		$heap->{control}->put("250 DELE command successful");
	} else {
		$heap->{control}->put("550 DELE command unsuccessful");
	}
}

sub MKD	{
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$fn = join(' ',@$fn);
	my $fs = $heap->{filesystem};
	
	my $ret = $fs->mkdir($fn);
	if ($ret == 1) {
		$fn =~ s/"/""/g; # doublequoting
		$heap->{control}->put("257 \"$fn\" directory created");
	} elsif ($ret == 2) {
		$fn =~ s/"/""/g; # doublequoting
		$heap->{control}->put("521 \"$fn\" directory already exists");
	} else {
		$heap->{control}->put("550 MKDIR $fn: Permission denied.");
	}
}

sub XMKD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$fn = join(' ',@$fn);
	my $fs = $heap->{filesystem};
	
	my $ret = $fs->mkdir($fn);
	if ($ret == 1) {
		$fn =~ s/"/""/g; # doublequoting
		$heap->{control}->put("257 \"$fn\" directory created");
	} elsif ($ret == 2) {
		$fn =~ s/"/""/g; # doublequoting
		$heap->{control}->put("521 \"$fn\" directory already exists");
	} else {
		$heap->{control}->put("550 MKDIR $fn: Permission denied.");
	}
}

sub RMD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$fn = join(' ',@$fn);
	my $fs = $heap->{filesystem};

	if ($fs->rmdir($fn)) {
		$heap->{control}->put("250 RMD command successful");
	} else {
		$heap->{control}->put("550 RMD $fn: Permission denied");
	}
}

sub XRMD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$fn = join(' ',@$fn);
	my $fs = $heap->{filesystem};

	if ($fs->rmdir($fs->cwd().$fn)) {
		$heap->{control}->put("250 RMD command successful");
	} else {
		$heap->{control}->put("550 RMD $fn: Permission denied");
	}
}

sub CDUP {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$fn = join(' ',@$fn);
	my $fs = $heap->{filesystem};

	if ($fs->chdir('..')) {
		$heap->{control}->put('257 "'.$fs->cwd().'" is current directory.');
	} else {
		$heap->{control}->put("550 ..: No such file or directory.");
	}
}

sub CWD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		$fn = join(' ',@$fn);
		my $fs = $heap->{filesystem};

		if ($fs->chdir($fn)) {
			$heap->{control}->put('257 "'.$fs->cwd().'" is current directory.');
		} else {
			$heap->{control}->put("550 $fn: No such file or directory.");
		}
	}
}

sub PWD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		$fn = join(' ',@$fn);
		my $fs = $heap->{filesystem};

		$heap->{control}->put('257 "'.$fs->cwd().'" is current directory.');
	}
}

sub PORT {
	my ($kernel, $session, $heap, $data_port) = @_[KERNEL, SESSION, HEAP, ARG0];

	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$data_port = join(' ',@$data_port);
	
	### Planning to use a Wheel here...

#	$heap->{control} = POE::Wheel::ReadWrite->new(
#			 Handle       => $handle,                # on this handle
#			 Driver       => new POE::Driver::SysRW, # using sysread and syswrite
#			 Filter       => new POE::Filter::FTPd::Control,
#			 InputEvent	=> 'receive',        # generating this event for requests
#			 ErrorEvent   => 'error',          # generating this event for errors
#			 FlushedEvent => 'flushed',        # generating this event for all-sent
#			);

	$heap->{last_port_cmd} = $data_port;
	$heap->{control}->put("200 PORT command successful.");

	$heap->{pasv} = 0;
}

sub PASV {
	my ($kernel, $session, $heap, $data_port) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	my $p1 = int ((int rand(65430)) / 256)+1025;
	my $p2 = (int rand(100))+1;
	$p1 -= $p2;

	POE::Component::Server::FTP::DataSession->new($heap->{params},{
		fs => $heap->{filesystem},
		port1 => $p1,
		port2 => $p2,
		rest => $heap->{rest},
	});

	$heap->{pasv} = 1;
	my $ip = $heap->{params}{ListenIP};
	$ip =~ s/\./,/g;
	print STDERR "ip is $ip\n";
	$heap->{control}->put("227 Entering Passive Mode. ($ip,$p1,$p2)");
}

sub LIST {
	my ($kernel, $session, $heap, $dirfile) = @_[KERNEL, SESSION, HEAP, ARG0];

	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}

	$dirfile = join(' ',@$dirfile);

	$heap->{control}->put("150 Opening ASCII mode data connection for /bin/ls.");

	if (defined $heap->{pending_session} && $heap->{pasv} == 1) {
		$kernel->post($heap->{pending_session}->ID => start_LIST => $dirfile);
	} else {
		POE::Component::Server::FTP::DataSession->new($heap->{params},{
			fs => $heap->{filesystem},
			data_port => $heap->{last_port_cmd},
			cmd => 'LIST',
			opt => $dirfile,
			pasv => $heap->{pasv},
		});
	}
}

sub NLST {
my ($kernel, $session, $heap, $dirfile) = @_[KERNEL, SESSION, HEAP, ARG0];

	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}

	$dirfile = join(' ',@$dirfile);

	$heap->{control}->put("150 Opening ASCII mode data connection for /bin/ls.");

	if (defined $heap->{pending_session} && $heap->{pasv} == 1) {
		$kernel->post($heap->{pending_session}->ID => start_NLST => $dirfile);
	} else {
		POE::Component::Server::FTP::DataSession->new($heap->{params},{
			fs => $heap->{filesystem},
			data_port => $heap->{last_port_cmd},
			cmd => 'NLST',
			opt => $dirfile,
		});
	}
}

sub STOR {
	my ($kernel, $session, $heap, $filename) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	my $fs = $heap->{filesystem};
	$filename = join(' ',@$filename);
	my $fh;

	if ($fh = $fs->open_write($filename)) {
		$heap->{control}->put("150 Opening BINARY mode data connection for $filename.");

		if (defined $heap->{pending_session} && $heap->{pasv} == 1) {
			$kernel->post($heap->{pending_session}->ID => start_STOR => $fh,
			{
				rest => $heap->{rest},
			});
		} else {
			POE::Component::Server::FTP::DataSession->new($heap->{params},{
				fs => $fs,
				data_port => $heap->{last_port_cmd},
				cmd => 'STOR',
				opt => $fh,
				rest => $heap->{rest},
			});
		}

	} else {
		$heap->{control}->put("553 Permission denied: $filename.");
	}
}

sub APPE {
	my ($kernel, $session, $heap, $filename) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	my $fs = $heap->{filesystem};
	$filename = join(' ',@$filename);
	my $fh;

	# the ,1 flag is for append
	if ($fh = $fs->open_write($filename,1)) {
		$heap->{control}->put("150 Opening BINARY mode data connection for $filename.");

		if (defined $heap->{pending_session} && $heap->{pasv} == 1) {
			$kernel->post($heap->{pending_session}->ID => start_STOR => $fh);
		} else {
			POE::Component::Server::FTP::DataSession->new($heap->{params},{
				fs => $fs,
				data_port => $heap->{last_port_cmd},
				cmd => 'STOR',
				opt => $fh,
			});
		}

	} else {
		$heap->{control}->put("553 Permission denied: $filename.");
	}
}

sub RETR {
	my ($kernel, $session, $heap, $filename) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	
	$filename = join(' ',@$filename);
	my $fs = $heap->{filesystem};
	my $fh;

	if ($fh = $fs->open_read($filename)) {
		$heap->{control}->put("150 Opening BINARY mode data connection for $filename.");
		if (defined $heap->{pending_session} && $heap->{pasv} == 1) {
			$kernel->post($heap->{pending_session}->ID => start_RETR => $fh,
			{
				rest => $heap->{rest},
			});
		} else {
			POE::Component::Server::FTP::DataSession->new($heap->{params},{
				fs => $fs,
				data_port => $heap->{last_port_cmd},
				cmd => 'RETR',
				opt => $fh,
				rest => $heap->{rest},
			});
		}
	} else {
		$heap->{control}->put("550 No such file or directory: $filename.");
	}
}

sub _default {
	my ($kernel, $heap, $session, $cmd, $args) = @_[KERNEL, HEAP, SESSION, ARG0, ARG1];

	if ($cmd =~ m/^_/) {
		$kernel->call($session->ID => _write_log => 4 => "NonHandled Event: $cmd(".join(", ", @$args).")");
	} else {
		$kernel->call($session->ID => _write_log => 4 => "UNSUPPORTED COMMAND: $cmd(".join(", ", @$args).")");

		$heap->{control}->put("500 '$cmd': command not understood");
	}
	
	return 0;
}

sub _reset_timeout {
	my ($kernel,$heap) = @_[KERNEL, HEAP];
	
	if (defined $heap->{time_out}) {
		$kernel->delay_adjust( $heap->{time_out}, $heap->{params}{'TimeOut'} );
	}
}

sub _write_log {
	my ($kernel, $session, $heap, $sender, $verbose, $msg) = @_[KERNEL, SESSION, HEAP, SENDER, ARG0, ARG1];
	if ($verbose <= $heap->{params}{'LogLevel'}) {
		# if we're not forking, then pass the logging off to the
		# main session
		if ($heap->{params}{_main_pid} == $$) {
			$kernel->call($heap->{params}{'Alias'} => _write_log => { type => (($sender->ID == $session->ID) ? 'C' : 'D'), msg => $msg, v => $verbose });
		} else {
			my $datetime = localtime();
			my $type = ($sender->ID == $session->ID) ? 'C' : 'D';
			print STDERR "[$datetime][$type".$sender->ID."] $msg\n";
		}
	}
}

1;
