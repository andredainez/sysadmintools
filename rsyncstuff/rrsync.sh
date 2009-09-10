#!/usr/bin/perl
# Name: /usr/local/bin/rrsync (should also have a symlink in /usr/bin)
# Purpose: Restricts rsync to subdirectory declared in .ssh/authorized_keys
# Author: Joe Smith <js-cgi@inwap.com> 30-Sep-2004
# Modified by: Wayne Davison <wayned@samba.org>
#
# Modified by BDV to add the use of sudo.
# Based on the version of rrsync included with rsync 3.0.6pre1.
# $Id: rrsync,v 1.2 2009-05-06 08:30:51 bdevuyst Exp $
#
use strict;

use Socket;
use Cwd 'abs_path';
use File::Glob ':glob';

# You may configure these values to your liking.  See also the section
# of options if you want to disable any options that rsync accepts.
use constant RSYNC => '/usr/bin/rsync';
use constant LOGFILE => 'rrsync.log';
use constant SUDO => '/usr/bin/sudo';
use constant SUDOUSER => 'root';

my $Usage = <<EOM;
Use 'command="$0 [-ro] SUBDIR"'
	in front of lines in $ENV{HOME}/.ssh/authorized_keys
EOM

our $ro = (@ARGV && $ARGV[0] eq '-ro') ? shift : '';	# -ro = Read-Only
our $subdir = shift;
die "$0: No subdirectory specified\n$Usage" unless defined $subdir;
$subdir = abs_path($subdir);
die "$0: Restricted directory does not exist!\n" if $subdir ne '/' && !-d $subdir;

# The client uses "rsync -av -e ssh src/ server:dir/", and sshd on the server
# executes this program when .ssh/authorized_keys has 'command="..."'.
# For example:
# command="rrsync logs/client" ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAIEAzGhEeNlPr...
# command="rrsync -ro results" ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAIEAmkHG1WCjC...
#
# Format of the envrionment variables set by sshd:
# SSH_ORIGINAL_COMMAND=rsync --server          -vlogDtpr --partial . ARG # push
# SSH_ORIGINAL_COMMAND=rsync --server --sender -vlogDtpr --partial . ARGS # pull
# SSH_CONNECTION=client_addr client_port server_port

my $command = $ENV{SSH_ORIGINAL_COMMAND};
die "$0: Not invoked via sshd\n$Usage"	unless defined $command;
die "$0: SSH_ORIGINAL_COMMAND='$command' is not rsync\n" unless $command =~ s/^rsync\s+//;
die "$0: --server option is not first\n" unless $command =~ /^--server\s/;
our $am_sender = $command =~ /^--server\s+--sender\s/; # Restrictive on purpose!
die "$0 -ro: sending to read-only server not allowed\n" if $ro && !$am_sender;

### START of options data produced by the cull_options script. ###

# These options are the only options that rsync might send to the server,
# and only in the option format that the stock rsync produces.

# To disable a short-named option, add its letter to this string:
our $short_disabled = 's';

our $short_no_arg = 'ACDEHIKLORSWXbcdgklmnoprstuvxz'; # DO NOT REMOVE ANY
our $short_with_num = 'B'; # DO NOT REMOVE ANY

# To disable a long-named option, change its value to a -1.  The values mean:
# 0 = the option has no arg; 1 = the arg doesn't need any checking; 2 = only
# check the arg when receiving; and 3 = always check the arg.
our %long_opt = (
  'append' => 0,
  'backup-dir' => 2,
  'bwlimit' => 1,
  'checksum-seed' => 1,
  'compare-dest' => 2,
  'compress-level' => 1,
  'copy-dest' => 2,
  'copy-unsafe-links' => 0,
  'daemon' => -1,
  'delay-updates' => 0,
  'delete' => 0,
  'delete-after' => 0,
  'delete-before' => 0,
  'delete-delay' => 0,
  'delete-during' => 0,
  'delete-excluded' => 0,
  'existing' => 0,
  'fake-super' => 0,
  'files-from' => 3,
  'force' => 0,
  'from0' => 0,
  'fuzzy' => 0,
  'iconv' => 1,
  'ignore-errors' => 0,
  'ignore-existing' => 0,
  'inplace' => 0,
  'link-dest' => 2,
  'list-only' => 0,
  'log-file' => 3,
  'log-format' => 1,
  'max-delete' => 1,
  'max-size' => 1,
  'min-size' => 1,
  'modify-window' => 1,
  'no-i-r' => 0,
  'no-implied-dirs' => 0,
  'no-r' => 0,
  'no-relative' => 0,
  'no-specials' => 0,
  'numeric-ids' => 0,
  'only-write-batch' => 1,
  'partial' => 0,
  'partial-dir' => 2,
  'remove-sent-files' => $ro ? -1 : 0,
  'remove-source-files' => $ro ? -1 : 0,
  'safe-links' => 0,
  'sender' => 0,
  'server' => 0,
  'size-only' => 0,
  'skip-compress' => 1,
  'specials' => 0,
  'suffix' => 1,
  'super' => 0,
  'temp-dir' => 2,
  'timeout' => 1,
  'use-qsort' => 0,
);

### END of options data produced by the cull_options script. ###

if ($short_disabled ne '') {
    $short_no_arg =~ s/[$short_disabled]//go;
    $short_with_num =~ s/[$short_disabled]//go;
}
$short_no_arg = "[$short_no_arg]" if length($short_no_arg) > 1;
$short_with_num = "[$short_with_num]" if length($short_with_num) > 1;

my $write_log = -f LOGFILE && open(LOG, '>>', LOGFILE);

chdir($subdir) or die "$0: Unable to chdir to restricted dir: $!\n";

my(@opts, @args);
my $in_options = 1;
my $last_opt = '';
my $check_type;
while ($command =~ /((?:[^\s\\]+|\\.[^\s\\]*)+)/g) {
  $_ = $1;
  if ($check_type) {
    push(@opts, check_arg($last_opt, $_, $check_type));
    $check_type = 0;
  } elsif ($in_options) {
    push(@opts, $_);
    if ($_ eq '.') {
      $in_options = 0;
    } else {
      die "$0: invalid option: '-'\n" if $_ eq '-';
      next if /^-$short_no_arg*(e\d*\.\w*)?$/o || /^-$short_with_num\d+$/o;

      my($opt,$arg) = /^--([^=]+)(?:=(.*))?$/;
      my $disabled;
      if (defined $opt) {
	my $ct = $long_opt{$opt};
	last unless defined $ct;
	next if $ct == 0;
	if ($ct > 0) {
	  if (!defined $arg) {
	    $check_type = $ct;
	    $last_opt = $opt;
	    next;
	  }
	  $arg = check_arg($opt, $arg, $ct);
	  $opts[-1] =~ s/=.*/=$arg/;
	  next;
	}
	$disabled = 1;
	$opt = "--$opt";
      } elsif ($short_disabled ne '') {
	$disabled = /^-$short_no_arg*([$short_disabled])/o;
	$opt = "-$1";
      }

      last unless $disabled; # Generate generic failure
      die "$0: option $opt has been disabled on this server.\n";
    }
  } else {
    if ($subdir ne '/') {
      # Validate args to ensure they don't try to leave our restricted dir.
      s#//+#/#g;
      s#^/##;
      s#^$#.#;
      die "Do not use .. in any path!\n" if m#(^|/)\\?\.\\?\.(\\?/|$)#;
    }
    push(@args, bsd_glob($_, GLOB_LIMIT|GLOB_NOCHECK|GLOB_BRACE|GLOB_QUOTE));
  }
}
die "$0: invalid rsync-command syntax or options\n" if $in_options;

@args = ( '.' ) if !@args;

if ($write_log) {
  my ($mm,$hh) = (localtime)[1,2];
  my $host = $ENV{SSH_CONNECTION} || 'unknown';
  $host =~ s/ .*//; # Keep only the client's IP addr
  $host =~ s/^::ffff://;
  $host = gethostbyaddr(inet_aton($host),AF_INET) || $host;
  printf LOG "%02d:%02d %-13s [%s]\n", $hh, $mm, $host, "@opts @args";
  close LOG;
}

# Note: This assumes that the rsync protocol will not be maliciously hijacked.
exec(SUDO, "-u", SUDOUSER, RSYNC, @opts, @args) or die "exec(rsync @opts @args) failed: $? $!";

sub check_arg
{
  my($opt, $arg, $type) = @_;
  $arg =~ s/\\(.)/$1/g;
  if ($subdir ne '/' && ($type == 3 || ($type == 2 && !$am_sender))) {
    $arg =~ s#//#/#g;
    die "Do not use .. in --$opt; anchor the path at the root of your restricted dir.\n"
      if $arg =~ m#(^|/)\.\.(/|$)#;
    $arg =~ s#^/#$subdir/#;
  }
  $arg;
}
