#!/usr/bin/perl

use Filesys::Virtual;
use POE qw(Component::Server::FTP);

POE::Component::Server::FTP->spawn(
	Alias           => 'ftpd',
	ListenPort      => 2112,
	Domain			=> 'teknikill.net',
	Version			=> 'ftpd v1.0',
	AnonymousLogin	=> 'deny', # deny, allow
	FilesystemClass => 'Filesys::Virtual::Plain',
	FilesystemArgs  => {
		'root_path' => '/',      # This is actual root for all paths
		'cwd'       => '/',      # Initial current working dir
		'home_path' => '/home', # Home directory for '~'
	}
);

$poe_kernel->run();
