#!/usr/bin/perl

use Filesys::Virtual;
use POE qw(Component::Server::FTP);

POE::Component::Server::FTP->spawn(
	Alias           => 'ftpd',				# ftpd is default
	ListenPort      => 2112,				# port to listen on
	Domain			=> 'blah.net',			# domain shown on connection
	Version			=> 'ftpd v1.0',			# shown on connection, you can mimic...
	AnonymousLogin	=> 'allow',				# deny, allow
	FilesystemClass => 'Filesys::Virtual::Plain',	# Currently the only one available
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
