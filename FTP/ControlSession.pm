package POE::Component::Server::FTP::ControlSession;

######################################################################
### POE::Component::Server::FTP::ControlSession
### L.M.Orchard ( deus_x@pobox.com )
### Modified by David Davis ( xantus@cpan.org )
###
### TODO:
### -- Better PASV port picking
### -- Support both ASCII and BINARY transfer types
### -- More logging!!
###
### Copyright (c) 2001 Leslie Michael Orchard.  All Rights Reserved.
### This module is free software; you can redistribute it and/or
### modify it under the same terms as Perl itself.
###
### Changes Copyright (c) 2003 David Davis and Teknikill Software
######################################################################

use strict;

use IO::Socket::INET;
use POE qw(Session Wheel::ReadWrite Driver::SysRW Wheel::SocketFactory);
use POE::Component::Server::FTP::DataSession;
use POE::Component::Server::FTP::ControlFilter;

sub DEBUG { 0 }

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
	my ($kernel, $heap, $opt) = @_[KERNEL, HEAP, ARG0];

	eval("use $opt->{FilesystemClass}");
	if ($@) {
		die "$@";
	}

	my $fs = ("$opt->{FilesystemClass}")->new($opt->{FilesystemArgs});

	# watch for SIGINT
	$kernel->sig('INT', 'signals');

	# start reading and writing
	$heap->{control} = new POE::Wheel::ReadWrite(
		Handle			=> $opt->{Handle},					# on this handle
		Driver			=> new POE::Driver::SysRW,	# using sysread and syswrite
		Filter			=> new POE::Component::Server::FTP::ControlFilter,
		InputEvent		=> 'receive',				# generating this event for requests
		ErrorEvent		=> 'error',					# generating this event for errors
		FlushedEvent	=> 'flushed',				# generating this event for all-sent
	);

	# maybe do this?
#	$heap->{fs_session} = POE::Wheel::Run->new(
#		Program => sub {
#			my $fs = ("$fs_class")->new($fs_args);
#		},
#		StdioFilter  => POE::Filter::Line->new(),
#		StderrFilter => POE::Filter::Line->new(),
#		StdoutEvent  => "_job_stdout",
#		StderrEvent  => "_job_stderr",
#		CloseEvent   => "_job_close",
#	);
#	$heap->{control}->put( "Job " . $heap->{job}->PID . " started." );

	$heap->{pasv} = 0;
	$heap->{auth} = 0;
	$heap->{host} = $opt->{PeerAddr};
	$heap->{port} = $opt->{PeerPort};
	$heap->{filesystem} = $fs;
	%{$heap->{params}} = %{ $opt };

	DEBUG && print "Control session started for $heap->{host} : $heap->{port}\n";

	$heap->{control}->put("220 $opt->{Domain} FTP server ($opt->{Version} ".localtime()." ready.)");
}

sub _stop {
	my $heap = $_[HEAP];
	DEBUG && print "Client session ended with $heap->{host} : $heap->{port}\n";
}

sub _child {
	my ($kernel, $heap, $action, $child) = @_[KERNEL, HEAP, ARG0, ARG1];

	if ($action eq 'create') {
		$heap->{pending_session} = $child;
	} elsif ($action eq 'lose') {
		$heap->{control}->put("226 Transfer complete.");
		delete $heap->{pending_session};
	}
}

sub receive {
	my ($kernel, $session, $heap, $cmd) = @_[KERNEL, SESSION, HEAP, ARG0];

	DEBUG && print "Received input from $heap->{host} : $heap->{port}\n";
	DEBUG && print "Args: ".join(',',@{$cmd->{args}})."\n";

	$kernel->post($session, $cmd->{cmd}, \@{$cmd->{args}});
}

sub error {
	my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

	if ($errnum) {
		DEBUG && print( "Session with $heap->{host} : $heap->{port} ",
						"encountered $operation error $errnum: $errstr\n"
					  );
	} else {
		DEBUG && print( "Client at $heap->{host} : $heap->{port} disconnected\n" );
	}

	# either way, stop this session
	delete $heap->{control};
}

sub flushed {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	DEBUG && print "Response has been flushed to $heap->{host} : $heap->{port}\n";

	$kernel->post($heap->{pending_session}, 'execute')
	  if (defined $heap->{pending_session});
}


sub signals {
	my ($heap, $signal_name) = @_[HEAP, ARG0];

	DEBUG && print( "Session with $heap->{host} : $heap->{port} caught SIG",
					$signal_name, "\n"
				  );
	# do not handle the signal
	return 0;
}

sub NOOP {
	my ($kernel, $session, $heap, $args) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	# reset a timeout timer?
	$heap->{control}->put("200 No-op okay.");
}

sub XSEN {
	my ($kernel, $session, $heap, $args) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	# TODO send a message to the terminal
	#$args = join(' ',@$args);
	
	$heap->{control}->put("453 Not Allowed");
}

sub QUIT {
	my ($kernel, $session, $heap, $args) = @_[KERNEL, SESSION, HEAP, ARG0];

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
			_write_log("Anonymous login denied.");
			$heap->{control}->put("530 Login incorrect.");
			$heap->{auth} = 0;
			return;
		}
		if ($fs->login($heap->{username}, $password)) {
			_write_log("User $heap->{username} logged in.");
			$heap->{control}->put("230 User $heap->{username} logged in.");
			$heap->{auth} = 1;
		} else {
			_write_log("Incorrect login");
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
	
	$heap->{rest} = $args->[0];
	$heap->{control}->put("350 Will attempt to restart at postion $args->[0].");
}

# Not implemented.
sub TYPE {
	my ($kernel, $session, $heap, $type) = @_[KERNEL, SESSION, HEAP, ARG0];
	
	$type = $type->[0];
	
	$heap->{control}->put("200 Type set to I.");
}

# Not implemented.
sub SYST {
	my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
	$heap->{control}->put("215 UNIX Type: L8");
}

sub ABOR {
	my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
	
	if (defined $heap->{pending_session}) {
		$kernel->post($heap->{pending_session} => 'data_throttle');
		$kernel->post($heap->{pending_session} => 'shutdown');
	}
	
	$heap->{control}->put("200 ABOR successfull");
	# TODO what do i send?
}

sub MDTM {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	$fn = join(' ',@$fn);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $fs = $heap->{filesystem};
		my @modtime = $fs->modtime($fs);
		if ($modtime[0] == 0) {
			$heap->{control}->put("550 MDTM $fn: Permission denied.\n");
		} else {
			$heap->{control}->put("213 ".$modtime[1]);
		}
	}
}

sub CHMOD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	my $mode = shift(@$fn);
	$fn = join(' ',@$fn);

	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $fs = $heap->{filesystem};

		if ($fs->chmod($mode, $fn)) {
			$heap->{control}->put("200 CHMOD command successful.");
		} else {
			$heap->{control}->put("550 CHMOD command unsuccessful");
		}
	}
}

sub DELE {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	$fn = join(' ',@$fn);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $fs = $heap->{filesystem};

		if ($fs->delete($fn)) {
			$heap->{control}->put("250 DELE command successful");
		} else {
			$heap->{control}->put("550 DELE command unsuccessful");
		}
	}
}

sub MKD	{
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	$fn = join(' ',@$fn);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $fs = $heap->{filesystem};
		
		my $ret = $fs->mkdir($fn);
		if ($ret == 1) {
			$fn =~ s/"/""/g; # doublequoting
			$heap->{control}->put("257 \"$fn\" directory created");
		} elsif ($ret == 2) {
			$fn =~ s/"/""/g; # doublequoting
			$heap->{control}->put("521 \"$fn\" directory already exists");
		} else {
			$heap->{control}->put("550 MKDIR $fn: Permission denied.\n");
		}
	}
}

sub XMKD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	$fn = join(' ',@$fn);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $fs = $heap->{filesystem};
		
		my $ret = $fs->mkdir($fn);
		if ($ret == 1) {
			$fn =~ s/"/""/g; # doublequoting
			$heap->{control}->put("257 \"$fn\" directory created");
		} elsif ($ret == 2) {
			$fn =~ s/"/""/g; # doublequoting
			$heap->{control}->put("521 \"$fn\" directory already exists");
		} else {
			$heap->{control}->put("550 MKDIR $fn: Permission denied.\n");
		}
	}
}

sub RMD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	$fn = join(' ',@$fn);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $fs = $heap->{filesystem};

		if ($fs->rmdir($fn)) {
			$heap->{control}->put("250 RMD command successful");
		} else {
			$heap->{control}->put("550 RMD $fn: Permission denied");
		}
	}
}

sub XRMD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	$fn = join(' ',@$fn);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $fs = $heap->{filesystem};

		if ($fs->rmdir($fs->cwd().$fn)) {
			$heap->{control}->put("250 RMD command successful");
		} else {
			$heap->{control}->put("550 RMD $fn: Permission denied");
		}
	}
}

sub CDUP {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	$fn = join(' ',@$fn);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $fs = $heap->{filesystem};

		if ($fs->chdir('..')) {
			$heap->{control}->put('257 "'.$fs->cwd().'" is current directory.');
		} else {
			$heap->{control}->put("550 ..: No such file or directory.");
		}
	}
}

sub CWD {
	my ($kernel, $session, $heap, $fn) = @_[KERNEL, SESSION, HEAP, ARG0];
	$fn = join(' ',@$fn);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
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
	$fn = join(' ',@$fn);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
	} else {
		my $fs = $heap->{filesystem};

		$heap->{control}->put('257 "'.$fs->cwd().'" is current directory.');
	}
}

sub PORT {
	my ($kernel, $session, $heap, $data_port) = @_[KERNEL, SESSION, HEAP, ARG0];

	$data_port = join(' ',@$data_port);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	### Planning to use a Wheel here...

	#$heap->{control} = new POE::Wheel::ReadWrite
#			(
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

	POE::Component::Server::FTP::DataSession->new({
		fs => $heap->{filesystem},
		port1 => $p1,
		port2 => $p2,
		rest => $heap->{rest},
	});

	$heap->{pasv} = 1;
	my $ip = $heap->{params}{ListenIP};
	$ip =~ s/\./,/g;
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
		$kernel->post($heap->{pending_session} => start_LIST => $dirfile);
	} else {
		POE::Component::Server::FTP::DataSession->new({
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
		$kernel->post($heap->{pending_session} => start_NLST => $dirfile);
	} else {
		POE::Component::Server::FTP::DataSession->new({
			fs => $heap->{filesystem},
			data_port => $heap->{last_port_cmd},
			cmd => 'NLST',
			opt => $dirfile
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
			$kernel->post($heap->{pending_session} => start_STOR => $fh, $heap->{rest});
		} else {
			POE::Component::Server::FTP::DataSession->new({
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
			$kernel->post($heap->{pending_session} => start_STOR => $fh);
		} else {
			POE::Component::Server::FTP::DataSession->new({
				fs => $fs,
				data_port => $heap->{last_port_cmd},
				cmd => 'APPE',
				opt => $fh,
			});
		}

	} else {
		$heap->{control}->put("553 Permission denied: $filename.");
	}
}

sub RETR {
	my ($kernel, $session, $heap, $filename) = @_[KERNEL, SESSION, HEAP, ARG0];
	$filename = join(' ',@$filename);
	if ($heap->{auth} == 0) {
		$heap->{control}->put("530 Not logged in");
		return;
	}
	my $fs = $heap->{filesystem};
	my $fh;

	_write_log("RETR $filename");

	if ($fh = $fs->open_read($filename)) {
		$heap->{control}->put("150 Opening BINARY mode data connection for $filename.");
		if (defined $heap->{pending_session} && $heap->{pasv} == 1) {
			$kernel->post($heap->{pending_session} => start_RETR => $fh, $heap->{rest});
		} else {
			POE::Component::Server::FTP::DataSession->new({
				fs => $fs,
				data_port => $heap->{last_port_cmd},
				cmd => 'RETR',
				opt => $fh,
				rest => $heap->{rest}
			});
		}
	} else {
		$heap->{control}->put
		  ("550 No such file or directory: $filename.");
	}
}

sub _default {
	my ($kernel, $heap, $cmd, $args) = @_[KERNEL, HEAP, ARG0, ARG1];

	if ($cmd =~ m/^_/) {
		DEBUG && print "NonHandled Event: $cmd(".join(", ", @$args).")\n";
	} else {
		DEBUG && print "UNSUPPORTED COMMAND: $cmd(".join(", ", @$args).")\n";

		$heap->{control}->put("500 '$cmd': command not understood");
	}
}

sub _write_log {
	my $datetime = localtime();

	print STDERR "[$datetime] ";
	print STDERR shift;
	print STDERR "\n";
}

sub _copy_fh {
	my ($fh_in, $fh_out) = @_;

	eval {
		my ($len, $buf, $offset, $written);
		my $blksize = (stat $fh_in)[11] || 16384;

		while($len = $fh_in->sysread($buf, $blksize)) {
			if (!defined $len) {
				next if $! =~ /^Interrupted/;
#				carp "System read error: $!\n";
			}
			$offset = 0;
			$written = 0;
			while ($len) {
				$written = $fh_out->syswrite($buf, $len, $offset) || 0;
				if ($!) {
#					print "WRITE ERROR: $!\n";
					sleep(1);
				}

#				or die "System write error: $!\n";
				$len    -= $written;
				$offset += $written;
			}
		}
	};

	_write_log("ERROR: $@\n") if ($@);
}

1;
