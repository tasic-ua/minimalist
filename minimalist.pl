#!/usr/local/bin/perl -w

use strict;
#
# Copyright (c) 1999-2005 Vladimir Litovka <vlitovka@gmail.com>
# Copyright (c) 2013 Taras Heychenko <tasic@academ.kiev.ua>
#
# Minimalist - Next version of Minimalistic Mailing List Manager.
#
# Redistribution and use in source and binary forms, with or without modification,
# are permitted provided that the following conditions are met:
# 
# 1. Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
# 
# 2. Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation and/or
# other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

use Fcntl ':flock';	# LOCK_* constants
use Mail::Header;
use Encode qw/encode decode/;
use Mail::Address;
use Config::Simple;
use POSIX qw(strftime);
use integer;
use utf8;

my $version = '0.99.2 Experimental';
my $config = "/usr/local/etc/minimalist.conf";

# Program name and arguments for launching if commands in message's body
my $running = $0." --body-controlled ".join ($", @ARGV);

# Lists' status bits
my $OPEN = 0;
my $RO = 1;
my $CLOSED = 2;
my $MANDATORY = 4;

my @languages = ();

#####################################################
# Default values
#
my %msgtxt = ();
my @blacklist = ();
my @removeheaders = ();
my @trusted = ();
my $status = $OPEN;
my $envelope_sender = "";
# Next var contains regex (will contain after config loading) to calculate rights
my $verify = 0; # By default eval($verify) returns false
my $list = '';
my $listname = '';
my $msg = "";
my $subject = "";
my @readonly = ();
my @writeany = ();
my @members = ();
my @rw = ();
my $to_gecos = "";
my @xtrahdr = ();
my $usermode = '';
my $suffix = '';
my $owner = '';
my $email = '';
my $msg_hdr;

my %cnf_param = (
	'auth_scheme' => 'password',
	'password' => '_'.$$.time.'_',	# Some pseudo-random value
	'listpwd' => '_'.$$.time.'_',		# Some pseudo-random value
	'userpwd' => '',
	'suffix' => '',
	'sendmail' => '/usr/sbin/sendmail',
	'delivery' => 'internal',
	'domain' => `uname -n`,
	'directory' => '/var/spool/minimalist',
	'security' => 'careful',
	'archive' => 'no',
	'archive type' => 'dir',
	'archive size' => 0,
	'archpgm' => 'BUILTIN',
	'status' => 'open',
	'copy to sender' => 'yes',
	'reply-to list' => 'no',
	'from' => '',
	'errors to' => 'drop',
	'modify subject' => 'yes',
	'maxusers' => 0,
	'maxrcpts' => 20,
	'delay' => 0,
	'maxsize' => 0,		# Maximum allowed size for message (incl. headers)
	'request valid' => 24,
	'logfile' => 'none',
	'log messages' => 'no',
	'list information' => 'yes',
	'strip rrq' => 'no',
	'remove resent' => 'no',
	'modify message-id' => 'no',
	'extra header' => '',
	'language' => "en",
	'list gecos' => '',
	'background' => 'no',
	'to recipient' => 'no',
	'list owner' => '',
	'dkim' => 'no',
	'remove headres' => 0,
# Languages support
	'charset' => 'us-ascii',
	'blocked robots' => 'CurrentlyWeAreBlockingNoRobot-Do__NOT__leaveThisBlank',	# -VTV-
	'cc on subscribe' => 'no');	# -VTV-

##
my $body_controlled = 0;
my $global_exit_status = 0;

chomp $cnf_param{'domain'};
$cnf_param{'admin'} = 'postmaster\@' . $cnf_param{'domain'};

########################################################
# >>>>>>>>>>>>>>> SELF - CONFIGURING <<<<<<<<<<<<<<<<< #
########################################################

while (defined $ARGV[0]) {
	if ($ARGV[0] eq '-c') {
		$config = $ARGV[1];
		shift @ARGV; shift @ARGV;
	}
	elsif ($ARGV[0] eq '-d') {
		$ARGV[1] =~ s|(.*)/$|$1|g;
		$config = $ARGV[1]."/minimalist.conf";
		shift @ARGV; shift @ARGV;
	}
	elsif ($ARGV[0] eq '--body-controlled') {
		$body_controlled = 1;
		shift @ARGV;
	}
	else { last; }
}

read_config($config, "global");
my $mesender = 'minimalist@' . $cnf_param{'domain'};	# For substitute in X-Sender header

&InitMessages();			# Init messages

####################################################################
# >>>>>>>>>>>>>>>>>>>>>>>> CHECK CONFIGURATION <<<<<<<<<<<<<<<<<<< #
####################################################################

if (defined $ARGV[0] and $ARGV[0] eq '-') {
	print "\nMinimalist v$version, pleased to meet you.\n".
				"Using \"$config\" as main configuration file\n\n";
	print	"================= Global configuration ================\n".
				"Directory: $cnf_param{'directory'}\n".
				"Administrative password: ".($cnf_param{'password'} =~ /^_[\d]+_$/ ? "not defined\n" : "ok\n").
				"Logging: $cnf_param{'logfile'}\n".
				"Log info about messages: $cnf_param{'log messages'}\n".
				"Background execution: $cnf_param{'background'}\n".
				"Authentication request valid at least $cnf_param{'request valid'} hours\n".
				"Blocked robots:";
	if ($cnf_param{'blocked robots'} !~ /__NOT__/) {
		foreach (split(/\|/, $cnf_param{'blocked robots'})) {
			print "\n\t$_"; 
		}
	}
	else { 
		print " no one"; 
	}

	if ( @blacklist ) {
		print "\nGlobal access list is:\n";
		foreach (@blacklist) {
			if ( $_ =~ s/^!(.*)//g ) { print "\t - ".$1." allowed\n" }
			else { print "\t - ".$_." disallowed\n" }
		};
	};
  print "\n\n";

	my %global_cnf = %cnf_param;

	while ( $ARGV[0] ) {
		%cnf_param = %global_cnf;

		$list = $ARGV[0];
		$listname = $list;
		if ($list ne '-') {
			unless(chdir("$cnf_param{'directory'}/$list")) {
				print " * There isn't such list \U$list\E\n\n";
				shift @ARGV; next;
			}
			read_config("config");
			print "================= \U$list\E ================\n".
						"Authentication scheme: $cnf_param{'auth_scheme'}\n";
			if ($cnf_param{'auth_scheme'} eq 'mailfrom') {
				print "Administrators: ";
				if ( @trusted ) {
					print "\n";
					foreach (@trusted) { print "\t . ".$_."\n"; }
				}
				else { print "not defined\n"; }
			}
			else {
				print "Administrative password: ".(! $cnf_param{'listpwd'} ? "empty" :
						$cnf_param{'listpwd'} =~ /^_[\d]+_$/ ? "not defined" : "Ok")."\n"; 
			}
		}

		my $archtype = '';
		if($cnf_param{'archive'} eq 'daily' or $cnf_param{'archive'} eq 'monthly' or $cnf_param{'archive'} eq 'yearly') {
			$archtype = $cnf_param{'archive type'};
		}

		print "Sendmail: $cnf_param{'sendmail'}\n".
					"Delivery method: $cnf_param{'delivery'}".
					($cnf_param{'delivery'} eq 'alias' ? " (destination: $cnf_param{'delivery_alias'})\n" : "\n").
					"Domain: $cnf_param{'domain'}\n".
					"Security: $cnf_param{'security'}\n".
					"Archiving: $cnf_param{'archive'}\n".
					($cnf_param{'archive'} ne 'no' ? " * Archiver: $cnf_param{'archpgm'}\n" : "").
					(length $archtype ? " * Archive to $archtype\n" : '').
					($cnf_param{'archive size'} != 0 ? " * Maximum message size: $cnf_param{'archive size'} bytes\n" : "").
					"Status:";
		if ($status) {
			print " read-only" if ($status & $RO);
			print " closed" if ($status & $CLOSED);
			print " mandatory" if ($status & $MANDATORY);
		}
		else { print " open"; }
		my $lo = ($list eq '-') ? '' : 
					(length $cnf_param{'list owner'})? $cnf_param{'list owner'} : "$listname-owner\@$cnf_param{'domain'}";
		print "\nCopy to sender: $cnf_param{'copy to sender'}\n".
					"Reply-To list: $cnf_param{'reply-to list'}\n".
					"List GECOS: ".($cnf_param{'list gecos'} ? $cnf_param{'list gecos'} : "empty")."\n".
					"Substitute From: ".($cnf_param{'from'} ? $cnf_param{'from'} : "none")."\n".
					"Admin: $cnf_param{'admin'}\n".
					(length $lo ? "List Owner: $lo\n" : '').
					"Errors from MTA: ".($cnf_param{'errors to'} eq 'drop' ? "drop" :
						($cnf_param{'errors to'} eq 'verp' ? "generate VERP" : "return to $cnf_param{'errors to'}"))."\n".
					"Modify subject: $cnf_param{'modify subject'}\n".
					"Modify Message-ID: $cnf_param{'modify message-id'}\n".
					"Notify on subscribe/unsibscribe event: $cnf_param{'cc on subscribe'}\n".
					"Maximal users per list: ".($cnf_param{'maxusers'} ? $cnf_param{'maxusers'} : "unlimited")."\n".
					"Maximal recipients per message: ".($cnf_param{'maxrcpts'} ? $cnf_param{'maxrcpts'} : "unlimited")."\n".
					"Delay between deliveries: ".($cnf_param{'delay'} ? $cnf_param{'delay'} : "none")."\n".
					"Maximal size of message: ".($cnf_param{'maxsize'} ? "$cnf_param{'maxsize'} bytes" : "unlimited")."\n".
					"Strip 'Return Receipt' requests: $cnf_param{'strip rrq'}\n".
					"List information: ".($cnf_param{"list information"} eq 'no' ? "no" : "yes".
						($cnf_param{"list information"} ne 'yes' ? ", archive at: " . $cnf_param{'list information'} : ""))."\n".
					"Language: $cnf_param{'language'}\n".
					"Charset: $cnf_param{'charset'}\n".
					"Fill To: with recipient's address: $cnf_param{'to recipient'}\n".
					"DKIM is $cnf_param{'dkim'}\n".
					"Header(s) to remove:";
					if($cnf_param{'remove headers'} && $#removeheaders >=0 ) {
						print "\n";
						foreach my $h (@removeheaders) {
							print "\t$h\n";
						}
					} else {
						print " none\n";
					}
		print	"Extra Header(s):";
					if(@xtrahdr) {
						print "\n";
						foreach my $xh (@xtrahdr) {
							print "\t",$xh,"\n";
						}
					} else {
						print " none\n";
					}
		
# Various checks
		$msg = "";
		$msg .= " * $cnf_param{'directory'} doesn't exist!\n" if (! -d $cnf_param{'directory'});
		$msg .= " * $cnf_param{'sendmail'} doesn't exist!\n" if (! -x $cnf_param{'sendmail'});
		$msg .= " * Invalid 'log messages' value '$cnf_param{'log messages'}'\n"
						if ($cnf_param{'log messages'} !~ /^yes$|^no$/i);
		$msg .= " * Invalid 'background' value '$cnf_param{'background'}'\n"
						if ($cnf_param{'background'} !~ /^yes$|^no$/i);
		$msg .= " * Invalid delivery method: $cnf_param{'delivery'}\n"
						if ($cnf_param{'delivery'} !~ /^internal|^alias/i);
		$msg .= " * Invalid domain '$cnf_param{'domain'}'\n"
						if ($cnf_param{'domain'} !~ /^(\w[-\w]*\.)+[a-z]{2,4}$/i);
		$msg .= " * Invalid security level '$cnf_param{'security'}'\n"
						if ($cnf_param{'security'} !~ /^none$|^careful$|^paranoid$/i);
		$msg .= " * Invalid 'copy to sender' value '$cnf_param{'copy to sender'}'\n"
						if ($cnf_param{'copy to sender'} !~ /^yes$|^no$/i);
		$msg .= " * Invalid 'modify subject' value '$cnf_param{'modify subject'}'\n"
						if ($cnf_param{'modify subject'} !~ /^yes$|^no$|^more$/i);
		$msg .= " * Invalid 'modify message-id' value '$cnf_param{'modify message-id'}'\n"
						if ($cnf_param{'modify message-id'} !~ /^yes$|^no$/i);
		$msg .= " * Invalid 'cc on subscribe' value '$cnf_param{'cc on subscribe'}'\n"
						if ($cnf_param{'cc on subscribe'} !~ /^yes$|^no$/i);
		$msg .= " * Invalid 'reply-to list' value '$cnf_param{'reply-to list'}'\n"
						if ($cnf_param{'reply-to list'} !~ /^yes$|^no$|\@/i);
		$msg .= " * Invalid 'from' value '$cnf_param{'from'}'\n"
						if ($cnf_param{'from'} !~ /\@|^$/i);
		$msg .= " * Invalid authentication request validity time: $cnf_param{'request valid'}\n"
						if ($cnf_param{'request valid'} !~ /^[0-9]+$/);
		$msg .= " * Invalid authentication scheme: $cnf_param{'auth_scheme'}\n"
						if ($cnf_param{'auth_scheme'} !~ /^mailfrom|^password/i);
		$msg .= " * Invalid archiving strategy '$cnf_param{'archive'}'\n"
						if ($cnf_param{'archive'} !~ /^no$|^daily$|^monthly$|^yearly$|^pipe$/i);
		$msg .= " * Invalid archive type '$cnf_param{'archive type'}'\n"
						if ($cnf_param{'archive type'} !~ /^dir$|^file$/i);
		$msg .= " * Invalid 'strip rrq' value '$cnf_param{'strip rrq'}'\n"
						if ($cnf_param{'strip rrq'} !~ /^yes$|^no$/i);
		$msg .= " * Invalid 'remove resent' value '$cnf_param{'remove resent'}'\n"
						if ($cnf_param{'remove resent'} !~ /^yes$|^no$/i);
		$msg .= " * Invalid language '$cnf_param{'language'}'\n"
						if (!grep(/^$cnf_param{'language'}$/, @languages));
		$msg .= " * Invalid 'to recipient' value '$cnf_param{'to recipient'}'\n"
						if ($cnf_param{'to recipient'} !~ /^yes$|^no$/i);
		if ($cnf_param{'archive'} eq 'pipe') {
			my ($arpg, ) = split(/\s+/, $cnf_param{'archpgm'}, 2);
			$msg .= " * $arpg doesn't exists!\n" if (! -x $arpg);
		}

		goto CfgCheckEnd if(length $msg);
		shift @ARGV;
	}

	CfgCheckEnd:

	print "\t=== FAILURE ===\n\nErrors are:\n".$msg."\n" if ($msg);
	print "\t=== WARNING ===\n\nConfiguration file '$config' does not exist.\n\n" if (! -f $config);
	exit 0;
}

####################################################################
# >>>>>>>>>>>>>>>>>>>>>>>>> START HERE <<<<<<<<<<<<<<<<<<<<<<<<<<< #
####################################################################

$list = $ARGV[0];
$listname = $list;
my $auth_seconds = $cnf_param{'request valid'} * 3600;	# Convert hours to seconds

my $message = "";
while (<STDIN>) {
  s/\r//g;		# Remove Windooze's \r, it is safe to do this
  $message .= $_;
 }
my ($header, $body) = split(/\n\n/, $message, 2); $header .= "\n";

undef $message;		# Clear memory, it doesn't used anymore

# Look for user's supplied password
# in header (in form: '{pwd: blah-blah}' )
# Further we will work with array so remove password from headers before
#FIXME some header line may end with "pwd". Should be defined more strict regexp.
while ($header =~ s/\{pwd:[ \t]*(\w+)\}//i) {
  $cnf_param{'userpwd'} = $1;
}
# in body, as very first '*password: blah-blah'
if (!$cnf_param{'userpwd'} && $body =~ s/^\*password:[ \t]+(\w+)\n+//i) {
  $cnf_param{'userpwd'} = $1;
}

$body =~ s/\n*$/\n/g;
$body =~ s/\n\.\n/\n \.\n/g;	# Single '.' treated as end of message

my @headers = split(/\n/,$header);
my $mh = Mail::Header->new(\@headers);

# Check SysV-style "From ". Stupid workaround for messages from robots, but
# with human-like From: header. In most cases "From " is the only way to
# find out envelope sender of message.
my $from_ = $mh->get("From ");
exit 0 if(defined $from_ and $from_ =~ /(MAILER-DAEMON|postmaster)@/i);

my @addrs = Mail::Address->parse($mh->get("From"));
my $from = lc($addrs[0]->address());
my $gecos = $addrs[0]->comment() ? $addrs[0]->comment() : $addrs[0]->phrase();

my @rplto = Mail::Address->parse($mh->get("Reply-To"));
my $mailto = (defined $rplto[0])? $rplto[0]->format() : $addrs[0]->format();

@addrs = Mail::Address->parse($mh->get("Sender"));
my $sender = (defined $addrs[0])? lc($addrs[0]->address()) : '';

@addrs = Mail::Address->parse($mh->get("X-Sender"));
my $xsender = (defined $addrs[0])? lc($addrs[0]->address()) : '';

exit 0 if (($xsender eq $mesender) || ($from eq $mesender));	# LOOP detected
exit 0 if (($from =~ /(mailer-daemon|postmaster)@/i) ||		# -VTV-
					($sender =~ /(mailer-daemon|postmaster)@/i) ||
					($xsender =~ /(mailer-daemon|postmaster)@/i));	# ignore messages from MAILER-DAEMON

# %header_tags hash contains all headers of incoming message
my %header_tags = map {$_ => 1} $mh->tags();

if ($cnf_param{'blocked robots'} !~ /__NOT__/) {
	foreach (split(/\|/, $cnf_param{'blocked robots'})) {
		exit 0 if(exists $header_tags{$_});   # disable loops from robots -VTV-
	}
}

# The "!" at begin of blacklist entry means that messages from this entry is allowed
BlacklistCheck: foreach (@blacklist) {				# Parse access control list
  if ( /^!(.*)$/ ) {
    last BlacklistCheck if ( $from =~ /$1$/i || $sender =~ /$1$/i || $xsender =~ /$1$/i) }
  else {
    exit 0 if ( $from =~ /$_$/i || $sender =~ /$_$/i || $xsender =~ /$_$/i) }
 };

my $qfrom = quotemeta($from);	# For use among with 'grep' function

#########################################################################
########################## Message to list ##############################
#
if ($list) {

	if (! -d "$cnf_param{'directory'}/$list" ) {
# Send message and exit.
		sendErrorExit($from, "Minimalist was called with the '$list' argument, but there is no such list in \'$cnf_param{'directory'}\'");
	}

 ##################################
 # Go to background, through fork #
 ##################################

	if ($cnf_param{'background'} eq 'yes') {

		my $forks = 0;

		FORK: {

			if (++$forks > 4) {
# Send message and exit.
				sendErrorExit($from, "Minimalist can not fork due to the following reason: Can't fork for more than 5 times");
			}
			if (my $pid = fork) {
# OK, parent here, exiting
				exit 0;
			}
			elsif (defined $pid) {
# OK, child here. Detach and do
				close STDIN;
				close STDOUT;
				close STDERR;
			}
			elsif ($! =~ /No more process/i) {
# EAGAIN, supposedly recoverable fork error, but no more than 5 times
				sleep 5;
				redo FORK;
			}
			else {
# weird fork error, exiting
				sendErrorExit($from, "Weird fork error: $!");
			}
		} # Label FORK
	}  # if ($background)

	chdir("$cnf_param{'directory'}/$list") or sendErrorExit($from, "Can not change dir to $cnf_param{'directory'}/$list");
	read_config("config");

# Remove or exit per List-ID (RFC2919)
	if(exists $header_tags{"List-ID"}){
		my $lid = $mh->get("List-ID");
		$mh->delete("List-ID");
		chomp $lid;
		exit 0 if ($lid =~ /$listname.$cnf_param{'domain'}/i);
	}

	$subject = decode('MIME-Header', $mh->get("Subject"));
	chomp $subject;

	if ($cnf_param{'modify subject'} ne 'no') {
		$subject =~ s/[\s]{2,}/ /g;
		if ($cnf_param{'modify subject'} eq 'more') {	# Remove leading "Re: "
			$subject =~ s/^.*:\s*(\[$listname\])/$1/ig 
		}
		else {				# change anything before [...] to Re:
			$subject =~ s/^(.*:\s*)+(\[$listname\])/Re: $2/ig;
		}

# Modify subject if it don't modified before
		if ($subject !~ /^(.*:\s*)?\[$listname\] /i) {
			$subject = "[$listname] ".$subject;
		}
	}
  
	open LIST, "list" or sendErrorExit($from, "Can not open list file for $list");
	@readonly = ();
	@writeany = ();
	@members = ();
	@rw = ();

	my $usrMaxSize;
	while (my $ent = <LIST>) {
		if ( $ent && $ent !~ /^#/ ) {
			chomp($ent);
			$ent = lc($ent);

# Get and remove per-user settings from e-mail
			my $userSet = '';
			$userSet = $1 if($ent =~ s/(>.*)$//);

# Check for '+' (write access) or '-' (read only access)
			if ($userSet =~ /-/) { push (@readonly, $ent); }
			elsif ($userSet =~ /\+/) { push (@writeany, $ent); }

# If user's maxsize
			if ($userSet !~ /#ms([0-9]+)/) { undef $usrMaxSize }
			else { $usrMaxSize = $1 }

# If suspended (!) or maxsize exceeded, do not put in @members
			if ($userSet =~ /!/ || (defined $usrMaxSize && length($body) > $usrMaxSize)) {
				push (@rw, $ent);
			}
			else {
				push (@members, $ent);
			}
		}
	}
	close LIST;
 
# If sender isn't admin, prepare list of allowed writers
	if (($cnf_param{'security'} ne 'none') && !eval($verify)) {
		push (@rw, @members);
		open LIST, "list-writers" and do {
			while (my $ent = <LIST>) {
				if ( $ent && $ent !~ /^#/ ) {
					chomp($ent);
					$ent = lc($ent);
 
# Get and remove per-user settings from e-mail
					$ent =~ s/(>.*)$//;
					my $userSet = (defined $1)? $1 : '';

# Check for '+' (write access) or '-' (read only access)
					if ($userSet =~ /-/) { push (@readonly, $ent); }
					elsif ($userSet =~ /\+/) { push (@writeany, $ent); }

					push (@rw, $ent);
				}
			}
			close LIST;
		}
	}

# If sender isn't admin and not in list of allowed writers
	if (($cnf_param{'security'} ne 'none') && !eval($verify) && !grep(/^$qfrom$/i, @rw)) {
		my $newmh = Mail::Header->new();
		$newmh->add("To", $mailto);
		$newmh->add("Subject", encode('MIME-Header', $subject));
		$mh = $newmh;
		$msg = $msgtxt{'2'.$cnf_param{'language'}};
		$msg .= " ($from) " . $msgtxt{'3'.$cnf_param{'language'}} . " minimalist\@$cnf_param{'domain'} ";
		$msg .= $msgtxt{'4'.$cnf_param{'language'}} . "\n";
		$msg .= "===========================================================================\n";
		$msg .= $body;
		$msg .= "\n===========================================================================\n";
	} 

# If list or sender in read-only mode and sender isn't admin and not
# in allowed writers
	elsif (($status & $RO || grep(/^$qfrom$/i, @readonly)) && !eval($verify) && !grep(/^$qfrom$/i, @writeany)) {
		my $newmh = Mail::Header->new();
		$newmh->add("To", $mailto);
		$newmh->add("Subject", encode('MIME-Header', $subject));
		$mh = $newmh;
		$msg = "$msgtxt{'5'.$cnf_param{'language'}} ($from) $msgtxt{'5.1'.$cnf_param{'language'}}\n";
		$msg .= "===========================================================================\n";
		$msg .= $body;
		$msg .= "\n===========================================================================\n";
	}
# If message size exceeds allowed maxsize
	elsif ($cnf_param{'maxsize'} && (length($header) + length($body) > $cnf_param{'maxsize'})) {
		my $newmh = Mail::Header->new();
		$newmh->add("To", $mailto);
		$newmh->add("Subject", encode('MIME-Header', $subject));
		$mh = $newmh;
		$msg = "$msgtxt{'6'.$cnf_param{'language'}} $cnf_param{'maxsize'} $msgtxt{'7'.$cnf_param{'language'}}\n\n";
		$msg .= $header;
	}
	else {		# Ok, all checks done.
		my $list_address = $listname . '@' . $cnf_param{'domain'};

		&logCommand("L=\"$list\" T=\"".decode('MIME-Header', $mh->get("Subject"))."\" S=".
								(length($header) + length($body)))
					if ($cnf_param{'log messages'} ne 'no');

		$cnf_param{'archive'} = 'no' if ($cnf_param{'archive size'} != 0 and length ($body) > $cnf_param{'archive size'});
		if ($cnf_param{'archive'} eq 'pipe') { arch_pipe(); }
		elsif ($cnf_param{'archive'} ne 'no') {
			if($cnf_param{'archive type'} eq 'file') {
				arch_file();
			} else {
				archive();
			}
		}

# Extract and remove all recipients of message. This information will be
# used later, when sending message to members except those who already
# received this message directly.
		my @hdrcpt = ();
		my @rcpts = ();
		$to_gecos = $cnf_param{'list gecos'};
		my @addrs = Mail::Address->parse($mh->get("To"));
		foreach my $j (@addrs) {
			push(@rcpts, $j->address());
			if($j->address eq $list_address && (length $cnf_param{'list gecos'})) {
				push(@hdrcpt, $cnf_param{'list gecos'});
			} else {
				push(@hdrcpt, $j->comment());
			}
		}
		@addrs = Mail::Address->parse($mh->get("Cc"));
		foreach my $j (@addrs) {
			push(@rcpts, $j->address());
			if($j->address eq $list_address && (length $cnf_param{'list gecos'})) {
				push(@hdrcpt, $cnf_param{'list gecos'});
			} else {
				push(@hdrcpt, $j->comment());
			}
		}

# Try to find gecos for list
		unless(length $to_gecos) {
			SearchGecos: for(my $i=0; $i<=$#rcpts; $i++) {
				if($rcpts[$i] eq $list_address) {
					$to_gecos = $hdrcpt[$i];
					last SearchGecos;
				}
			}
		}

# If there was To: and Cc: headers, put them back in message's header
		if (@rcpts && $cnf_param{'to recipient'} eq 'no') {
# If there is administrator's supplied GECOS, use it instead of user's supplied
			$mh->delete("To");
			$mh->delete("Cc");

			my @addr = Mail::Address->new($hdrcpt[0], $rcpts[0]);
			$mh->add("To", $addr[0]->format());
			my $cc = "";
			for(my $i=1; $i < @rcpts; $i++ ) {
				@addr = Mail::Address->new($hdrcpt[$i], $rcpts[$i]);
				$cc .= $addr[0]->format() . ",";
			}
			if(length $cc) {
				$cc =~ s/,$//;
				$mh->add("Cc", $cc);
			}
		}

# Remove conflicting headers
		$mh->delete("x-list-server");
		$mh->delete("precedence");

		%header_tags = map {$_ => 1} $mh->tags();
		if ($cnf_param{'remove resent'} eq 'yes') {
			foreach my $h (keys %header_tags) {
				$mh->delete($h) if($h =~ /^resent-/i);
			}
		}

		if ($cnf_param{'strip rrq'} eq 'yes') {		# Return Receipt requests
			$mh->delete("return-receipt-to");
			$mh->delete("disposition-notification-to");
			$mh->delete("x-confirm-reading-to");
		}

		if ($cnf_param{'modify message-id'} eq 'yes') {	# Change Message-ID in outgoing message
			my $old_msgid = $mh->get("message-id");
			chomp $old_msgid;
			$old_msgid =~ s/^<(.*)>$/$1/;
			$mh->delete("message-id");
			my $msgid = "MMLID_".int(rand(100000));
			$mh->add("Message-id", "<$msgid-$old_msgid>");
		}

		$mh->add("Precedence", "list"); # For vacation and similar programs

		if ($cnf_param{'modify subject'} ne 'no') {
			$mh->delete("subject");
			$mh->add("Subject", encode('MIME-Header', $subject));
		}

		if($cnf_param{'dkim'} eq 'yes') {
			$mh->delete("reply-to");
			$mh->add("Reply-To:", $mh->get("From"));
			$mh->delete("From");
			my $f_gecos = undef;
			if(length($gecos) > 0 and $gecos =~ /[\S]+/ ) {
				$f_gecos = "$gecos via ";
			} else {
				$f_gecos = $tmp_from . " via ";
			}
			$f_gecos .= (length($to_gecos))? $to_gecos : $list_address;
			my $adr = Mail::Address->new($f_gecos, $list_address);
			$mh->add("From:", $adr->format());
		} else {
# Remove original Reply-To unconditionally, set configured one if it is
			$mh->delete("reply-to");
			if ($cnf_param{'reply-to list'} eq 'yes') { 
				my $adr = Mail::Address->new($to_gecos, $list_address);
				$mh->add("Reply-to:",$adr->format());
			}
			elsif ($cnf_param{'reply-to list'} ne 'no') {
				$mh->add("Reply-to:",$cnf_param{'reply-to list'});
			}

			if ($cnf_param{'from'} ne '') {
				$mh->delete("From");
				my $adr = Mail::Address->parse($cnf_param{'from'});
				$mh->add("From",$adr->format());
			}
		}

		if ($cnf_param{"list information"} ne 'no') {
# --- Preserve List-Archive if it's there
			my @tags = $mh->tags();
			my $listarchive = $mh->get("List-Archive");
			chomp($listarchive = (defined $listarchive)? $listarchive : '');
# --- Remove List-* headers
			foreach my $h (@tags) {
				$mh->delete($h) if($h =~ /^list-/i);
			}

# FIXME Should be changed to name-list address
			$mh->add("List-Help", "<mailto:$mesender?subject=help>");
			$mh->add("List-Subscribe", "<mailto:$mesender?subject=subscribe%20$list>");
			$mh->add("List-Unsubscribe", "<mailto:$mesender?subject=unsubscribe%20$list>");
			$mh->add("List-Post", "<mailto:$list_address>");
			if(length $cnf_param{'list owner'}) {
				$mh->add("List-Owner", "<mailto:$cnf_param{'list owner'}>");
			} else {
				$mh->add("List-Owner", "<mailto:$listname-owner\@$cnf_param{'domain'}>");
			}

			if ($cnf_param{"list information"} ne 'yes') {
				$mh->add("List-Archive", $cnf_param{"list information"});
			}
			elsif (length $listarchive) {
				$mh->add("List-Archive", $listarchive);
			}
		}
		$mh->add("List-ID", "<$listname.$cnf_param{'domain'}>");
		$mh->add("X-List-Server", "Minimalist v$version");
#$header .= "X-List-Server: Minimalist v$version <http://www.mml.org.ua/>\n"; FIXME
		$mh->add("X-BeenThere", $list_address);

		my @tags = $mh->tags();
		if(@removeheaders) {
			foreach my $hdr (@removeheaders) {
				$mh->delete($hdr) if(grep(/^$hdr$/i, @tags));
			}
		}

		if(@xtrahdr) {
			&substitute_extra();
			foreach my $hdr (@xtrahdr) {
				$mh->add(undef, $hdr);
			}
		}

		&do_MIME_message;

		if ($cnf_param{'delivery'} eq 'internal') {

			push(@rcpts, $from) if ($cnf_param{'copy to sender'} eq 'no');	# @rcpts will be _excluded_

# Sort by domains
			my @t = Invert ('@', '!', @members);
			@members = sort @t;
			@t = Invert ('@', '!', @rcpts);
			@rcpts = sort @t;

			my @recipients = ();
			for (my $r=0, my $m=0; $m < @members; ) {
				if ($r >= @rcpts || $members[$m] lt $rcpts[$r]) {
					push (@recipients, $members[$m++]); }
				elsif ($members[$m] eq $rcpts[$r]) { $r++; $m++; }
				elsif ($members[$m] gt $rcpts[$r]) { $r++ };
			}

			@recipients = Invert ('!', '@', @recipients);

#########################################################
# Send message to recipients ($maxrcpts per message)

			my $rcs = 0;
			my $bcc = "";

			foreach my $one (@recipients) {
				if ($rcs == $cnf_param{'maxrcpts'}) {
					sendPortion($bcc);
					$bcc = ''; $rcs = 0;	# Clear counters
					sleep $cnf_param{'delay'} if ($cnf_param{'delay'});
				}
				if (length $one) {
					$bcc .= "$one ";
					$rcs++;
				}
			}
			sendPortion($bcc);	# Send to rest subscribers
		}
		else {	# Alias delivery
			open MAIL, "| $cnf_param{'sendmail'} $cnf_param{'delivery_alias'}";
			print MAIL $mh->as_string()."\n".$body;
			close MAIL;
		}

		$msg = '';	# Clear message, don't send anything anymore
	}
}
else {

#########################################################################
######################## Message to Minimalist ##########################
#
# Allowed commands:
#	subscribe <list> [<e-mail>]
#	unsubscribe <list> [<e-mail>]
#	mode <list> <e-mail> <set> [<setParam>]
#	suspend <list>
#	resume <list>
#	maxsize <list> <maxsize>
#	auth <code>
#	which [<e-mail>]
#	info [<list>]
#	who <list>
#	body
#	help
	my @bodyCommands = ();

	$subject = decode('MIME-Header', $mh->get("Subject"));
	chomp $subject;
	$subject =~ s/^.*?: //g;	# Strip leading 'Anything: '

	$list = '';
	$email = '';
	my $cmd = '';
	($cmd, $list, $email) = split (/\s+/, $subject, 3);
	$cmd = (defined $cmd)? lc($cmd) : '';
	$list = (defined $list)? lc($list) : '';
	$listname = (defined $list)? lc($list) : '';

	if (!$cmd || $cmd eq 'body') {	# Commands are in message's body
		@bodyCommands = split (/\n+/, $body);
		$mh->delete("Subject");
		$mh->add("X-MML-Password", "{pwd: $cnf_param{'userpwd'}}") if(length $cnf_param{'userpwd'});

		my $errors = 0;
		foreach $cmd (@bodyCommands) {
			last if ($cmd =~ /^(stop|exit)/i);

			open MML, "|$running";
			$mh->delete("Subject");
			$mh->add("Subject", "$cmd");
			print MML $mh->as_string(),"\n\n";
			close MML;
			last if ($? && ++$errors > 9);	# Exit if too many "bad syntax" errors
		}
		exit 0;
	}

	if ($cmd eq 'mode') {
		my $eml = '';
		($eml, $usermode) = split (/\s+/, $email, 2);
		$email = $eml;
	}

	if (length $email) {
		my @addrs = Mail::Address->parse($email);
		$email = lc($addrs[0]->address());
	}

	$msg = "";
	$msg_hdr = Mail::Header->new;
	$msg_hdr->add("To", $mailto);
	$msg_hdr->add("Subject", encode('MIME-Header', $subject));
	$msg_hdr->add("X-Sender", $mesender);
	$msg_hdr->add("X-List-Server", "Minimalist v$version");
 
	if ($cmd eq 'help') {
		$msg .= $msgtxt{'1'.$cnf_param{'language'}};
	} elsif ($cmd eq 'auth' && (my $authcode = $list)) {
		my ($cmd, $list, $email, $cmdParams) = getAuth($authcode);

		if ($cmd) {		# authentication code is valid
			chdir "$cnf_param{'directory'}/$list";
			read_config("config");

			$msg_hdr->add("List-ID", "<$listname.$cnf_param{'domain'}>");
			$owner = "$listname-owner\@$cnf_param{'domain'}";

			my $ok;
			if ($cmd eq 'subscribe' || $cmd eq 'unsubscribe') {
				$ok = eval("$cmd(0)");
			} else {	# suspend, resume, maxsize
				$ok = &chgSettings($cmd, $list, $email, $cmdParams);
			}

			if ($ok && $cnf_param{'logfile'} ne 'none') {
				&logCommand("$cmd $list$suffix".($email eq $from ? "" : " $email")." $cmdParams");
			}
		} else {
			$msg .= $msgtxt{'8'.$cnf_param{'language'}}.$authcode.$msgtxt{'9'.$cnf_param{'language'}}
		}
	} elsif ($cmd eq 'which') {
		$email = $list;	# $list means $email here
		if ($email && ($email ne $from) && !eval($verify)) {
			$msg .= $msgtxt{'10'.$cnf_param{'language'}};
		} else {
			&logCommand($subject) if ($cnf_param{'logfile'} ne 'none');
			$email = $from if (!$email);

			$msg .= $msgtxt{'11'.$cnf_param{'language'}}."$email:\n\n";

# Quote specials (+)
			$email =~ s/\+/\\\+/g;	# qtemail

			chdir $cnf_param{'directory'};
			opendir DIR, ".";
			while (my $dir = readdir DIR) {
				if (-d $dir && $dir !~ /^\./) {	# Ignore entries starting with '.'
					foreach my $f ("", "-writers") {
						open LIST, "$dir/list".$f and do {
							ReadList: while (<LIST>) {
								chomp;
								if ($_ =~ /$email(>.*)?$/i) {
									$msg .= "* \U$dir\E$f".&txtUserSet($1);
									last ReadList;
								}
							}
							close LIST;
						}	# open LIST
					}	# foreach
				}
			}		# readdir
			closedir DIR;
		}
	} else {		# Rest commands use list's name as argument
 
		if ($list =~ s/^(.*?)(-writers)$/$1/) {	# -writers ?
			$suffix = $2;
		}

		my %cmds = (cSub => 'subscribe',
								cUnsub => 'unsubscribe',
								cInfo => 'info',
								cWho => 'who',
								cSuspend => 'suspend',
								cResume => 'resume',
								cMaxsize => 'maxsize',
								cMode => 'mode');

		my $qcmd = quotemeta($cmd);
		if (! grep(/^$qcmd$/, %cmds)) { # Bad syntax or unknown instruction.
			goto BadSyntax;
		} elsif ( ($list ne '') && (! -d "$cnf_param{'directory'}/$list") ) {
			$msg .= $msgtxt{'12'.$cnf_param{'language'}}." \U$list\E ".$msgtxt{'13'.$cnf_param{'language'}}.
							" minimalist\@$cnf_param{'domain'} ".$msgtxt{'14'.$cnf_param{'language'}};
		} elsif ( ($cmd eq $cmds{cSub} || $cmd eq $cmds{cUnsub}) && ($list ne '') ) {
			chdir "$cnf_param{'directory'}/$list";
			read_config("config");
#   exit 0 if ($header =~ /(^|\n)list-id:\s+(.*)\n/i && $2 =~ /$list.$cnf_param{'domain'}/i);
			$msg_hdr->add("List-ID", "<$list.$cnf_param{'domain'}>");
			$owner = "$list-owner\@$cnf_param{'domain'}";

# Check for possible loop
			my $melist = "$list\@$cnf_param{'domain'}";
			$email = '' if(!defined $email && !length $email);
			exit 0 if (($from eq $melist) || ($email eq $mesender) || ($email eq $melist));

			if (eval($verify)) {
				&logCommand($subject) if (eval("$cmd(1)") && $cnf_param{'logfile'} ne 'none');
			} elsif (($email ne '') && ($email ne $from)) {
				$msg .= $msgtxt{'15'.$cnf_param{'language'}};
			} elsif (($cmd eq $cmds{cSub}) && ($status & $CLOSED)) {
				$msg .= $msgtxt{'16'.$cnf_param{'language'}}.$owner;
			} elsif (($cmd eq $cmds{cUnsub}) && ($status & $MANDATORY)) {
				$msg .= $msgtxt{'17'.$cnf_param{'language'}}.$owner;
			} else {
				if ($cnf_param{'security'} ne 'paranoid') {
					&logCommand($subject) if (eval("$cmd(0)") && $cnf_param{'logfile'} ne 'none');
				} else {
					$msg = genAuthReport( genAuth($cmd) );
				}
			}
		}	# subscribe/unsubscribe
		elsif ($cmd eq $cmds{cInfo}) {
			&logCommand($subject) if ($cnf_param{'logfile'} ne 'none');
			if ($list ne '') {
				$msg .= $msgtxt{'23'.$cnf_param{'language'}}." \U$list\E\n\n";
				$msg .= read_info("$cnf_param{'directory'}/$list/info");
			} else {
				$msg .= $msgtxt{'24'.$cnf_param{'language'}}." $cnf_param{'domain'}:\n\n";
				if (open(INFO, "$cnf_param{'directory'}/lists.lst")) {
					while (<INFO>) {
						$msg .= $_ if (! /^#/);
					}
					close INFO;
				}
			}
		}
		elsif (($cmd eq $cmds{cWho}) && ($list ne '')) {
			my @whoers = ();
			chdir "$cnf_param{'directory'}/$list";
			read_config("config");
			$msg_hdr->add("List-ID", "<$list.$cnf_param{'domain'}>");

			if (eval($verify)) {
				&logCommand($subject) if ($cnf_param{'logfile'} ne 'none');
				$msg .= $msgtxt{'25'.$cnf_param{'language'}}." \U$list\E$suffix:\n\n";
				if (open(LIST, "list".$suffix)) {
					while (<LIST>) {
						next if(/^#/);
						chomp;
						push (@whoers, $_);
					}
					if (@whoers) {
						my @t = sort(Invert ('@', '!', @whoers));
						@whoers = Invert ('!', '@', @whoers);
						foreach my $ent (@whoers) {
							$ent =~ s/(>.*)?$//;
							$msg .= $ent.&txtUserSet($1);
						}
					}
					close LIST;
				}
				$msg .= $msgtxt{'25.1'.$cnf_param{'language'}}.@whoers."\n";
			} else { 
				$msg .= $msgtxt{'26'.$cnf_param{'language'}};
			}
		}
# NOTE: $email here means value of maxsize
		elsif ((($cmd eq $cmds{cSuspend} || $cmd eq $cmds{cResume}) && $list) ||
						($cmd eq $cmds{cMaxsize}) && $list && $email =~ /[0-9]+/ ) {

			chdir "$cnf_param{'directory'}/$list";
			read_config("config");
			$msg_hdr->add("List-ID", "<$list.$cnf_param{'domain'}>");

			if (eval($verify) || $cnf_param{'security'} ne 'paranoid') {
				&logCommand($subject) if(&chgSettings($cmd, $list, $from, $email) && $cnf_param{'logfile'} ne 'none');
			} else {
				$msg = genAuthReport( genAuth($cmd, $email) );
			}
		}
		elsif (($cmd eq $cmds{cMode}) && $list && $email &&
					($usermode =~ s/^(reset|reader|writer|usual|suspend|resume|maxsize)\s*([0-9]+)?$/$1/i) ) {
			my $cmdParams = $2;

			chdir "$cnf_param{'directory'}/$list";
			read_config("config");
			$msg_hdr->add("List-ID", "<$list.$cnf_param{'domain'}>");

# Only administrator allowed to change settings
			if (eval($verify)) {
				&logCommand($subject) if (&chgSettings($usermode, $list, $email, $cmdParams) && $cnf_param{'logfile'} ne 'none');
			} else { # Not permitted to set usermode
				$msg .= $msgtxt{'44'.$cnf_param{'language'}};
			}
		} else {
			BadSyntax:		# LABEL HERE !!!
			$msg_hdr->delete("Subject");
			$msg_hdr->add("Subject", encode("MIME-Header",decode($cnf_param{'charset'}, $msgtxt{'27.0'.$cnf_param{'language'}})));
			$msg .= "* $subject *\n".$msgtxt{'27'.$cnf_param{'language'}};
			$global_exit_status = 10 if ($body_controlled);
		}
	}	# Rest commands

	$mh = $msg_hdr if($msg ne '');
	cleanAuth();		# Clean old authentication requests
}

if ($msg ne '') {

	$mh->add("From", "Minimalist Manager <$mesender>");
	$mh->add("MIME-Version", "1.0");
	$mh->add("Content-Type", "text/plain; charset=$cnf_param{'charset'}");
	$mh->add("Content-Transfer-Encoding", "8bit");
	$msg = $mh->as_string() . $msg;
	$msg =~ s/\n*$//g;

	open MAIL, "| $cnf_param{'sendmail'} -t -f $mesender";
	print MAIL "$msg\n\n-- \n".$msgtxt{'28'.$cnf_param{'language'}}."\n";
	close MAIL;
}

exit $global_exit_status;

#########################################################################
######################## Supplementary functions ########################

# Convert plain/text messages to multipart/mixed or
# append footer to existing MIME structure
#
sub do_MIME_message {
	my $msgcharset = "";
	my %ctypeh = ();

	my $footer = read_info("$cnf_param{'directory'}/$list/footer");
	return unless(length $footer);	# If there isn't footer, do nothing

	my $encoding = '7bit';
	my $ctyped = $mh->get("Content-Type");
	chomp($ctyped = (defined $ctyped)? $ctyped : '');

# Check if there is Content-Type and it isn't multipart/*
# FIXME Need to remove mixed/related from regex
	if (!(length $ctyped) || $ctyped !~ /^multipart\/(mixed|related)/i) {
		if($ctyped =~ /charset="?(.*?)"?[;\s]/i) {
			$msgcharset = lc($1);
		}
		$encoding = $mh->get("Content-Transfer-Encoding");
		chomp($encoding = (defined $encoding)? $encoding : '7bit');

# If message is 7/8bit text/plain with same charset without preset headers in
# footer, then simply add footer to the end of message
		if ($ctyped =~ /^text\/plain/i && $encoding =~ /[78]bit/i &&
				($cnf_param{'charset'} eq $msgcharset || $cnf_param{'charset'} eq 'us-ascii') &&
				$footer !~ /^\*hdr:[ \t]+/i) {
			$body .= "\n\n".$footer;
		}
		else {
# Move Content-* fields to MIME entity
			my @tags = $mh->tags();
			foreach my $t (@tags) {
				next unless($t =~ /^content-/i);
				$ctypeh{$t} = $mh->get($t);
				chomp $ctypeh{$t};
				$mh->delete($t);
			}

			my $boundary = "MML_".time()."_$$\@".int(rand(10000)).".$cnf_param{'domain'}";
			$mh->add("MIME-Version", "1.0") unless(length $mh->get("MIME-Version"));
			$mh->add("Content-Type", "multipart/mixed;\n\tboundary=\"$boundary\"");

			if ($footer !~ s/^\*hdr:[ \t]+// && $cnf_param{'charset'}) {
				$footer = "Content-Type: text/plain; charset=$cnf_param{'charset'}; name=\"footer.txt\"\n".
				"Content-Disposition: inline\n".
				"Content-Transfer-Encoding: 8bit\n\n".$footer;
			}

# Make body
			my $ct = "";
			foreach my $h (keys %ctypeh) {
				next if($h =~ /^content-length/i);
				$ct .= "$h: ".$ctypeh{$h}."\n";
			}
			$body = "\nThis is a multi-part message in MIME format.\n".
			"\n--$boundary\n".
			$ct.
			"\n$body".
			"\n--$boundary\n".
			$footer.
			"\n--$boundary--\n";
		}
	}
	else {	# Have multipart message
		my $level = 1; 
		my @boundary = ();
		$ctyped =~ /boundary="?(.*?)"?[;\s]/i;
		$boundary[0] = $boundary[1] = $1;
		my $pos = 0;

		THROUGH_LEVELS:
		while ($level) {
			my $hdrpos = index ($body, "--$boundary[$level]", $pos) + length($boundary[$level]) + 3;
			my $hdrend = index ($body, "\n\n", $hdrpos);
			my $entity_hdr = substr ($body, $hdrpos,  $hdrend - $hdrpos)."\n";

			$entity_hdr =~ /(^|\n)Content-Type:[ \t]+(.*\n([ \t]+.*\n)*)/i;
			$ctyped = $2;

			if ($ctyped =~ /boundary="?(.*?)"?[;\s]/i) {
				$level++;
				$boundary[$level] = $1;
				$pos = $hdrend + 2;
				next;
			}
			else {
				my $process_level = $level;
				while ($process_level == $level) {
					my $difflevel = 0;
# Looking for nearest boundary
					$pos = index ($body, "\n--", $hdrend);

# If nothing found, then if it's last entity, add footer
# to end of body, else return error
					if ($pos == -1) {
						if ($level == 1) { $pos = length ($body); }
						last THROUGH_LEVELS;
					}

					$hdrend = index ($body, "\n", $pos+3);
					my $bound = substr ($body, $pos+3, $hdrend-$pos-3);

# End of current level?
					if ($bound eq $boundary[$level]."--") { $difflevel = 1; }
# End of previous level?
					elsif ($bound eq $boundary[$level-1]."--") { $difflevel = 2; }

					if ($difflevel) {
						$pos += 1;
						$level -= $difflevel;
						if ($level > 0) {
							$pos += length ("--".$boundary[$level]."--");
						}
					}
# Next part of current level
					elsif ($bound eq "$boundary[$level]") {
						$pos += length ("$boundary[$level]") + 1;
					}
# Next part of previous level
					elsif ($bound eq "$boundary[$level-1]") {
						$pos++;
						$level--;
					}
# else seems to be boundary error, but do nothing
				}
			}
		}	# while THROUGH_LEVELS

		if ($pos != -1) {
# If end of last level not found, workaround this
			if ($pos == length($body) && $body !~ /\n$/) {
				$body .= "\n";
				$pos++;
			}

# Modify last boundary - it will not be last
			substr($body, $pos, length($body)-$pos) = "--$boundary[1]\n";

# Prepare footer and append it with really last boundary
			if ($footer !~ s/^\*hdr:[ \t]+// && $cnf_param{'charset'}) {
				$footer = "Content-Type: text/plain; charset=$cnf_param{'charset'}; name=\"footer\"\n".
									"Content-Transfer-Encoding: 8bit\n\n".$footer;
			}
			$body .= $footer."\n--$boundary[1]--\n";
		}
# else { print "Non-recoverable error while processing input file\n"; }
	}
}

#................... SUBSCRIBE .....................
sub subscribe {

	my $trustedcall = shift;
	my $cc = '';
	my $deny = 0;
	my $cause = '';
	$msg = '';

# Clear any spoofed settings
	$email =~ s/>.*$//;

	$email = $from unless(length $email);
	$cc = "$email," if ($email ne $from);

	if (open LIST, "list".$suffix) {
		while(<LIST>) {
			next if(/^\s*#/);
			chomp;
			push @members, $_;
		}
		close LIST;
		my $eml = quotemeta($email);
# Note comments (#) and settings
		if (grep(/^$eml(>.*)?$/i, @members)) {
			$deny = 1;
			$cause = $msgtxt{'29'.$cnf_param{'language'}}." \U$list\E$suffix";
		} elsif (!$trustedcall && $cnf_param{'maxusers'} > 0 ) {
			if ($suffix) {
				open LIST, "list";
			}		# Count both readers/writers and writers
			else {
				open LIST, "list-writers";
			}
			while(<LIST>) {
				next if(/^\s*#/);
				chomp;
				push @members, $_;
			}
			close LIST;
			if (@members >= $cnf_param{'maxusers'}) {
				$deny = 1;
				$cc .= "$owner," if(length $owner);
				$cause = $msgtxt{'30'.$cnf_param{'language'}}.$cnf_param{'maxusers'}.") @ \U$list\E";
			}
		}
	}

	my $LIST;
	if(!$deny) {
		open $LIST, ">>list".$suffix or sendErrorExit($from, "Can not open $list list file list$suffix for subscribe of $email");
	}

	$cc .= "$owner," if($cnf_param{'cc on subscribe'} =~ /yes/i && !$deny);

	if (length $cc) {
		$cc =~ s/,\s*$//g;;
		$msg_hdr->add("Cc", $cc);
	}

	$msg .= $msgtxt{'40'.$cnf_param{'language'}}." $email,\n\n";

	if (!$deny) {
		&lockf($LIST, 'lock');
		print $LIST "#Subscribed by email ".(strftime "%a %b %e %H:%M:%S %Y", localtime),"\n";
		print $LIST "$email\n";
		&lockf($LIST);
		$msg .= $msgtxt{'31'.$cnf_param{'language'}}." \U$list\E$suffix ";
		my $i = read_info("$cnf_param{'directory'}/$list/info");
		if(defined $i and length $i) {
			$msg .=$msgtxt{'32'.$cnf_param{'language'}}.$i;
		}
	} else {
		$msg .= "$msgtxt{'33'.$cnf_param{'language'}} \U$list\E$suffix $msgtxt{'34'.$cnf_param{'language'}}:\n\n";
		$msg .= "* $cause\n\n $msgtxt{'35'.$cnf_param{'language'}} $owner";
		close $LIST;
	}

	return !$deny;
}

#................... UNSUBSCRIBE .....................
sub unsubscribe {

	my $cc = "$owner," if ( $cnf_param{'cc on subscribe'} =~ /yes/i );
	my $ok = 0;

	if ($email) {
		$cc .= "$email," if ($email ne $from);
	} else {
		$email = $from;
	}

	if ($cc) {
		$cc =~ s/,\s*$//g;
		$msg_hdr->add("Cc", $cc);
	}

	my $LIST;
	if (open $LIST, "list".$suffix) {
		my @lines = ();
		my $qtemail = $email;
		$qtemail =~ s/\+/\\\+/g;	# Change '+' to '\+' (by Volker)
		my $unsub = 0;
		
		while (<$LIST>) {
			if(/^$qtemail/) {
				chomp;
				$lines[@lines] = '#' . $_ . "  Unsubscribed " . (strftime "%a %b %e %H:%M:%S %Y", localtime)."\n";
				$unsub++;
			} else {
				push(@lines,$_);
			}
		}
		close $LIST;

		if ($unsub) {
			rename "list".$suffix , "list".$suffix.".bak";
			open $LIST, ">list".$suffix;
			&lockf($LIST, 'lock');
			$ok = print $LIST @lines;
			&lockf($LIST);
			if ($ok) {
				$msg .= $msgtxt{'36'.$cnf_param{'language'}}.$email.$msgtxt{'37'.$cnf_param{'language'}};
				unlink "list".$suffix.".bak";
			} else {
				rename "list".$suffix.".bak" , "list".$suffix;
				&genAdminReport('unsubscribe', $email);
				$msg .= $msgtxt{'38'.$cnf_param{'language'}}.$email.$msgtxt{'38.1'.$cnf_param{'language'}}."$list\n";
			}
		} else {
			close $LIST;
			$msg .= $msgtxt{'36'.$cnf_param{'language'}}.$email.$msgtxt{'39'.$cnf_param{'language'}};
		}
	} else {
		sendErrorExit($from, "Can not open $list list file list$suffix for unsubscribe of $email");
	}

	return $ok;
}

sub genAuthReport {

	my $authcode = shift;
	$msg_hdr = Mail::Header->new;
	$msg_hdr->add("To", $from);
	$msg_hdr->add("Subject", "auth $authcode");

	my $msg = <<_EOF_ ;
$msgtxt{'18'.$cnf_param{'language'}}

	$subject

$msgtxt{'19'.$cnf_param{'language'}}
$mesender $msgtxt{'20'.$cnf_param{'language'}}

       auth $authcode

$msgtxt{'21'.$cnf_param{'language'}} $cnf_param{'request valid'} $msgtxt{'22'.$cnf_param{'language'}}
_EOF_
	return $msg;
}

sub genAdminReport {

	my $rqtype = shift;
	my $email = shift;

my $adminreport = <<_EOF_ ;
From: Minimalist Manager <$mesender>
To: $cnf_param{'admin'}
Subject: Error processing
Precedence: High

ERROR:
    Minimalist was unable to process '$rqtype' request on $list for $email.
    There was an error while writing into file "list$suffix".
_EOF_

	open MAIL, "| $cnf_param{'sendmail'} -t -f $mesender";
	print MAIL "$adminreport\n\n-- \nSincerely, the Minimalist\n";
	close MAIL;
}

sub sendErrorExit {

	my $receiver = shift;
	my $error = shift;

	my $t = time();

	my $hdr = Mail::Header->new();
	$hdr->add("From", $mesender);
	$hdr->add("To", $receiver);
	$hdr->add("Subject", "Minimalist error");
	$hdr->add("X-List-Server", "Minimalist v$version");
	$hdr->add("MIME-Version", "1.0");
	$hdr->add("Content-Type", "text/plain; charset=$cnf_param{'charset'}");
	$hdr->add("Content-Transfer-Encoding", "8bit");
	my $to_user = $hdr->as_string()."\n";
	$to_user .= $msgtxt{'45'.$cnf_param{'language'}} . $cnf_param{'admin'};
	$to_user .= $msgtxt{'46'.$cnf_param{'language'}} . $t;

	open MAIL, "| $cnf_param{'sendmail'} -t -f $mesender";
	print MAIL "$to_user\n\n-- \nSincerely, the Minimalist\n";
	close MAIL;

	$hdr = Mail::Header->new();
	$hdr->add("From", $mesender);
	$hdr->add("To", $cnf_param{'admin'});
	$hdr->add("Subject", "Minimalist error");
	$hdr->add("X-List-Server", "Minimalist v$version");
	$hdr->add("MIME-Version", "1.0");
	$hdr->add("Content-Type", "text/plain; charset=$cnf_param{'charset'}");
	$hdr->add("Content-Transfer-Encoding", "8bit");
	$to_user = $hdr->as_string()."\n";
	$to_user .= "Minimalist error: $error\n";
	$to_user .= "Code: $t\n";

	open MAIL, "| $cnf_param{'sendmail'} -t -f $mesender";
	print MAIL "$to_user\n\n-- \nSincerely, the Minimalist\n";
	close MAIL;

	exit 0;
}


# returns user settings in plain/text format
sub txtUserSet {

	my ($userSet, $indicateNO) = @_;
	my $usrmsg = '';
	my $i = 0;

	if ($userSet) {
		$usrmsg = " :";
# Permissions
		if ($userSet =~ /\+/) { $usrmsg .= $msgtxt{'43.1'.$cnf_param{'language'}}; $i++; }
		elsif ($userSet =~ /-/) { $usrmsg .= $msgtxt{'43.2'.$cnf_param{'language'}}; $i++; }
# Suspend
		if ($userSet =~ /!/) { $usrmsg .= ($i++ ? "," : "").$msgtxt{'43.3'.$cnf_param{'language'}} };
# Maxsize
		if ($userSet =~ /#ms([0-9]+)/) { $usrmsg .= ($i++ ? "," : "").$msgtxt{'43.4'.$cnf_param{'language'}}.$1 };
	}
	elsif ($indicateNO) {
		$usrmsg .= " :".$msgtxt{'43'.$cnf_param{'language'}};
	}

	$usrmsg .= "\n";
	return $usrmsg;
}

# Changes specified user settings, preserves other 
sub chgUserSet {
	my ($curSet, $pattern, $value) = @_;

	$curSet = '>' if (!$curSet);		# If settings are empty, prepare delimiter

	if ($curSet !~ s/$pattern/$value/g) {	# Change settings
		$curSet .= $value if ($value);	# or add new settings
	}

	$curSet = '' if ($curSet eq '>');	# If setings are empty, remove delimiter

	return $curSet;
}

sub chgSettings {

	my ($usermode, $list, $email, $cmdParams) = @_;
	my @lines = ();
	my $newSet = '';
	my $currentSet = '';
	my $ok = 0;

	if(open LIST, "list".$suffix) {
		while (<LIST>) {
			chomp;
			push (@lines, lc($_));
		}
		close LIST;

# Quote specials
		my $qtemail = $email;
		$qtemail =~ s/\+/\\\+/g;

		SearchLines: for (my $i=0; $i < @lines; $i++) {
			next if($lines[$i] =~ /^\s*#/);
			if ($lines[$i] =~ /^($qtemail)(>.*)?$/) {
				$currentSet = $2;
# Ok, user found
				if ($usermode eq 'reset') {
					$newSet = &chgUserSet($currentSet, '.*');
				} elsif ($usermode eq 'usual') {
					$newSet = &chgUserSet($currentSet, '[-\+]+');
				} elsif ($usermode eq 'reader') {
					$newSet = &chgUserSet($currentSet, '[-\+]+', '-');
				} elsif ($usermode eq 'writer') {
					$newSet = &chgUserSet($currentSet, '[-\+]+', '+');
				} elsif ($usermode eq 'suspend') {
					$newSet = &chgUserSet($currentSet, '!+', '!');
				} elsif ($usermode eq 'resume') {
					$newSet = &chgUserSet($currentSet, '!+');
				} elsif ($usermode eq 'maxsize') {
					if ($cmdParams+0 == 0) {
						$newSet = &chgUserSet($currentSet, '(#ms[0-9]+)+');
					} else {
						$newSet = &chgUserSet($currentSet, '(#ms[0-9]+)+', "#ms".($cmdParams+0));
					}
				}

				$lines[$i] = $email.$newSet;
				$currentSet = '>';	# Indicate, that user found, even if there are no settings
				last SearchLines;
			}
		}
	} else {
		sendErrorExit($from, "Can not open $list list file list$suffix for change settings of $email");
	}

	if($currentSet) {		# means, that user found
		my $users = '';
		foreach (@lines) {
			$users .= "$_\n";	# prepare plain listing
		}

		rename "list".$suffix, "list".$suffix.".bak";
		my $LIST;
		open $LIST, ">list".$suffix or sendErrorExit($from, "Can not open $list list file list$suffix for change settings of $email");
		&lockf($LIST, 'lock');
		$ok = print $LIST $users;
		&lockf($LIST);

		if ($ok) {
			$msg_hdr->add("Cc", $email) if($email ne $from);
			$msg .= $msgtxt{'41'.$cnf_param{'language'}}.$email.$msgtxt{'42'.$cnf_param{'language'}}."\U$list\E".
							&txtUserSet($newSet, 1);
			unlink "list".$suffix.".bak";
		} else {	# Write unsuccessfull, report admin
			rename "list".$suffix.".bak", "list".$suffix;
			&genAdminReport('mode', $email);
			$msg .= $msgtxt{'38'.$cnf_param{'language'}}.$email.$msgtxt{'38.1'.$cnf_param{'language'}}."$list\n";
		}
	} else { # User not found
		$msg .= $msgtxt{'36'.$cnf_param{'language'}}.$email.$msgtxt{'39'.$cnf_param{'language'}};
	}

	return $ok;
}

##########################################################################

#................... READ CONFIG .....................
sub read_config {

	my ($fname, $global) = @_;

# Config variables that should be defined only in global configuration file
	my %g_vars = ("directory"=>1, "password"=>1,"request valid"=>1, "blocked robots"=>1,"logfile"=>1,
                "log messages"=>1,"background"=>1);

# Config variables that should be defined only in local configuration files
	my %l_vars = ("auth"=>1, "list gecos"=>1, "to recipient"=>1, "list name"=>1);

	my @lowercased = ("request valid", "background", "errors to", "security", "archive", "copy to sender",
	                  "reply-to list", "modify subject", "strip rrq", "modify message-id", "remove resent",
										"cc on subscribe", "charset", "auth_scheme", "to recipient", "archive type");

	return unless(-e $fname);
	my $cfg = new Config::Simple($fname);

	my %ld_params = $cfg->vars();

	ReadLine: foreach my $i (keys %ld_params) {
		my $j = $i;
		$j =~ s/^default\.//;

		if($j =~ /^blacklist/i && defined $global) {
			@blacklist = expand_lists(split(':', $ld_params{$i}));
			next ReadLine;
		}

		if($j=~ /^auth/i && !(defined $global)) {
			my $auth_args = '';
			($cnf_param{'auth_scheme'}, $auth_args) = split(/\s+/, $ld_params{'default.auth'}, 2);
			$cnf_param{'auth_scheme'} = lc($cnf_param{'auth_scheme'});
			if ($cnf_param{'auth_scheme'} eq 'mailfrom') {
				$auth_args =~ s/\s+//g;
				@trusted = expand_lists(split(':', $auth_args));
			}
			else { 
				$cnf_param{'listpwd'} =  $auth_args;
			}
			next ReadLine;
		}

		if($j =~ /^remove headers/i) {
			$cnf_param{'remove headers'} = 1;
			@removeheaders = expand_lists(split(':',$ld_params{$i}));
		}

		if(exists $g_vars{$j}) {
			$cnf_param{$j} = $ld_params{$i} if(defined $global);
		}
		elsif(exists $l_vars{$j}) {
			$cnf_param{$j} = $ld_params{$i} unless(defined $global);
		}
		else {
			$cnf_param{$j} = $ld_params{$i};
		}
	}

	if($cnf_param{"delivery"} =~ s/^alias\s+(.*)$/$1/i) {
		$cnf_param{"delivery_alias"} = $cnf_param{"delivery"};
		$cnf_param{"delivery"} = "alias";
	}

	if($cnf_param{"domain"} =~ /^\|/) {
# Domain name getting from external program
		$cnf_param{"domain"} = eval("`".substr($cnf_param{"domain"}, 1)."`");
		chomp $cnf_param{"domain"};
	}

	if($cnf_param{"archive"} =~ s/^pipe\s+(.*)$/$1/i) {
		$cnf_param{"archpgm"} = $cnf_param{"archive"};
		$cnf_param{"archive"} = "pipe";
	}

	my @statuses;
	
	if(ref($cnf_param{"status"}) eq "ARRAY") {
		@statuses = @{$cnf_param{"status"}};
	} else {
		$statuses[0] = $cnf_param{"status"};
	}
	unless($#statuses<0) {
		$status = 0;
		my %strel = ("open"=>$OPEN, "ro"=>$RO, "closed"=>$CLOSED, "mandatory"=>$MANDATORY);
		foreach (@statuses) {
			my $s = lc($_);
			$status += $strel{$s};
		}
	}

# In global config only 'yes' or 'no' allowed
	$cnf_param{"reply-to list"} = 'no' 
		if((defined $global) && ($cnf_param{"reply-to list"} ne 'yes'));

# Check for bound values
	$cnf_param{"maxrcpts"} = 20 if($cnf_param{"maxrcpts"} < 1);
	$cnf_param{"maxrcpts"} = 50 if($cnf_param{"maxrcpts"} > 50);

	$cnf_param{"list information"} = lc($cnf_param{"list information"})
		if($cnf_param{"list information"} =~ /^(yes|no)$/i);
	$cnf_param{"list information"} = 'no'
		if(defined $global && ($cnf_param{"list information"} ne 'yes'));

# Config::Simple can not read multiply lines with the same name. So for backward
# compatibility with minimalist config we read such lines (if any) by "minimalist method"
	if(exists $cnf_param{"extra header"}) {
		if (open(CONF, $fname)) {
		my $i = -1;
		  while (<CONF>) {
				if($_ =~ /^extra header/i) {
					my ($directive, $tmp_xtrahdr) = split(/=/, $_, 2);
					$tmp_xtrahdr =~ s/^\s*(.*?)\s*$/$1/gs;
					$tmp_xtrahdr =~ s/^\\n//gi;
					my @lns = split(/\\n/, $tmp_xtrahdr);
					foreach my $hdr (@lns) {
						if($hdr =~ /^\\/) {
							$xtrahdr[$i] .= $hdr;
						} else {
							$i++;
							$xtrahdr[$i] = $hdr;
						}
					}
				}
			}
			close CONF;
		}
		else {
			sendErrorExit($from, "Error reading configuration file $fname");
		}
		delete $cnf_param{"extra header"};
	}

	foreach (@lowercased) {
#		warn $_ unless(defined $cnf_param{$_});
		$cnf_param{$_} = lc($cnf_param{$_});
	}

# check what we verify
	if ( ($cnf_param{'auth_scheme'} eq 'mailfrom') && @trusted ) {
		$verify = 'grep(/^$qfrom$/i, @trusted) || ($cnf_param{\'userpwd\'} eq $cnf_param{\'password\'})';
	}
	else {
		$verify = '($cnf_param{\'userpwd\'} eq $cnf_param{\'listpwd\'}) || ($cnf_param{\'userpwd\'} eq $cnf_param{\'password\'})';
	}

	my $me = "minimalist\@$cnf_param{'domain'}";

	$listname = $cnf_param{'list name'} if(exists $cnf_param{'list name'});

	if ($cnf_param{'errors to'} eq 'drop') { $envelope_sender = "-f $me"; }
	elsif ($cnf_param{'errors to'} eq 'admin') { $envelope_sender = "-f " . $cnf_param{"admin"}; }
	elsif ($cnf_param{'errors to'} ne 'sender' && $cnf_param{'errors to'} ne 'verp') {
		$envelope_sender = "-f " . $cnf_param{'errors to'};
	}

	$cnf_param{'log messages'} = 'no' if ($cnf_param{'logfile'} eq 'none');
	$cnf_param{'archive size'} = 0 if ($cnf_param{'archive'} eq 'no');
	$cnf_param{'maxrcpts'} = 1 if ($cnf_param{'errors to'} eq 'verp' || $cnf_param{'to recipient'} eq 'yes');

	$cnf_param{'charset'} ='utf-8' if($cnf_param{'language'} ne 'en');

	return;
}

sub substitute_extra {

	foreach my $extra (@xtrahdr) {
		$extra =~ s/\\a/$cnf_param{'admin'}/ig;
		$extra =~ s/\\d/$cnf_param{'domain'}/ig;
		$extra =~ s/\\l/$list/ig;
		$extra =~ s/\\o/$list-owner\@$cnf_param{'domain'}/ig;
		$extra =~ s/\\t/ /ig;
		$extra =~ s/\\s/ /ig;
	}
	return;
}

#..........................................................
sub expand_lists {
	my (@junk) = @_;
	my @result = ();

	foreach my $s (@junk) {
		if ( $s =~ s/^\@// ) {	# Expand items, starting with '@'
			if (open(IN, $s)) {
				while (<IN>) {
					chomp;
					$result[@result] = $_;
				}
				close IN;
			} else {
				sendErrorExit($from, "Can not open IN file $s in sub expand_lists")
			}
		}
		elsif ($s ne '') {
			$result[@result] = $s;
		}
	}
	return @result;
}

#.......... Read file and substitute all macroses .........
sub read_info {
	my $fname = shift;
	my $tail ="";

	return unless(defined $fname);
	if (open(TAIL, $fname)) {
		$tail .= $_ while (<TAIL>);
		close TAIL;

		if ($tail) {
			$tail =~ s/\\a/$cnf_param{'admin'}/ig;
			$tail =~ s/\\d/$cnf_param{'domain'}/ig;
			$tail =~ s/\\l/$list/ig;
			$tail =~ s/\\o/$list-owner\@$cnf_param{'domain'}/ig;
		}
	}

	return $tail;
}

#.......... Send ready portion of message ............
sub sendPortion {
	my $bcc = shift;
	return unless(length $bcc);

	chop $bcc;

	if($cnf_param{'to recipient'} eq 'yes') {
		my $a = Mail::Address->parse($bcc);
		$mh->add("To", $a->format());
	}
	if ($cnf_param{'errors to'} eq 'verp') {
		my $verp_bcc = $bcc;
		$verp_bcc =~ s/\@/=/g;
	 	$envelope_sender = "-f $list-owner-$verp_bcc\@$cnf_param{'domain'}";
	}

	my $hdr = $mh->as_string();

	open MAIL, "| $cnf_param{'sendmail'} $envelope_sender $bcc";
	print MAIL $hdr."\n\n".$body;
	close MAIL;
}

#.................... Built-in archiver ..........................
sub archive {

	my @date = localtime;
	my $year = 1900 + $date[5];
	my $month = 1 + $date[4];
	my $day = $date[3];

	my $path = "archive/";
	mkdir($path, 0755) if (! -d $path);

	my %rel = ("yearly"=>$year, "monthly"=>$month, "daily"=>$day);

	foreach my $key ("yearly", "monthly", "daily") {
		$path .= $rel{$key}."./";
		mkdir($path, 0755) if (! -d $path);
		last if ($key eq $cnf_param{'archive'});
	}

	my $msgnum = 0;
	if (open(NUM, $path."SEQUENCE")) {
		read NUM, $msgnum, 16;
		$msgnum = int($msgnum);
		close NUM;
	}

	if(open ARCHIVE, ">$path".$msgnum) {
		print ARCHIVE $header."\n".$body;
		close ARCHIVE;
	}

	if(open NUM, ">$path"."SEQUENCE") {
		print NUM $msgnum+1;
		close NUM;
	}
}

sub arch_file {
	my $path = "archive/";
	mkdir($path, 0755) if (! -d $path);
	if($cnf_param{'archive'} eq 'daily') {
		$path .= strftime "%Y%m%d", localtime;
	} elsif($cnf_param{'archive'} eq 'montly') {
		$path .= strftime "%Y%m", localtime;
	} elsif($cnf_param{'archive'} eq 'yearly') {
		$path .= strftime "%Y", localtime;
	} else {
		$path .= strftime "%Y%m", localtime;
	}

	open ARCHIVE, ">>$path";
	print ARCHIVE $header."\n".$body;
	close ARCHIVE;
}


#.................... External archiver ..........................
sub arch_pipe {

 if(open (ARCHIVE, "| $cnf_param{'archpgm'}")) {
	 print ARCHIVE $header."\n".$body;
	 close (ARCHIVE);
	}
	return;
}

#.................... Generate authentication code ...............
sub genAuth {

	my $cmd = shift;
	my $cmdParams = shift;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
	my ($authcode) = $mon.$mday.$hour.$min.$sec."-$$";

	mkdir ("$cnf_param{'directory'}/.auth", 0750) if (! -d "$cnf_param{'directory'}/.auth");

	if(open AUTH, ">$cnf_param{'directory'}/.auth/$authcode") {
		print AUTH "$cmd $list$suffix $from $cmdParams\n";
		close AUTH;
	} else {
		sendErrorExit($from, "Can not isend authcode $authcode to $from");
	}

	return $authcode;
}

#................. Check for authentication code ...............
sub getAuth {

	my ($cmd, $list, $email, $cmdParams);
	my $authcode = shift;
	my $authfile = "$cnf_param{'directory'}/.auth/$authcode";

	if ($authcode =~ /^[0-9]+\-[0-9]+$/) {
		open AUTH, $authfile and do {
			my $authtask = <AUTH>; chomp $authtask;
			close AUTH; unlink $authfile;

			($cmd, $list, $email, $cmdParams) = split(/\s+/, $authtask);

			if ($list =~ s/^(.*?)(-writers)$/$1/) {	# -writers ?
				$suffix = $2;
			}

			return ($cmd, $list, $email, $cmdParams);
		}
	}
}

#............... Clean old authentication requests .............
sub cleanAuth {

	my $now = time;
	my $dir = "$cnf_param{'directory'}/.auth";
	my $mark = "$dir/.lastclean";
	my @ftime = ();

	if (! -f $mark) {
		open LC, "> $mark" or sendErrorExit($from, "Can not create auth file $mark for $from\n$!");
		close LC;
		return;
	} else {
		@ftime = stat(_);
		return if ($now - $ftime[9] < $auth_seconds);	# Return if too early
	}

	utime $now, $now, $mark;	# Touch .lastclean
	opendir DIR, $dir;
	while (my $entry = readdir DIR) {
		if ($entry !~ /^\./ && -f "$dir/$entry") {
			@ftime = stat(_);
			unlink "$dir/$entry" if ($now - $ftime[9] > $auth_seconds);
		}
	}
	closedir DIR;
}

#............................ Locking .........................
sub lockf {
	my ($FD, $lock) = @_;

	if (defined $lock) {		# Lock FD
		flock $FD, LOCK_EX;
		seek $FD, 0, 2;
	}
	else {			# Unlock FD and close it
		flock $FD, LOCK_UN;
		close $FD;
	}
}

#......................... Logging activity ....................
sub logCommand {
	my ($command) = @_;

	$command =~ s/\n+/ /g;
	$command =~ s/\s{2,}/ /g;	# Prepare for logging

	my $FILE;
	open $FILE, ">>$cnf_param{'logfile'}" or sendErrorExit($from, "Can not open logfile $cnf_param{'logfile'}");
	&lockf($FILE, 1);
	my @ct = localtime();
	my $log_gecos = ($gecos) ? "($gecos)" : "";

	binmode($FILE,':utf8');
	printf $FILE "%s %02d %02d:%02d %d %s\n",
		(qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec))[$ct[4]],
		$ct[3], $ct[2], $ct[1], 1900+$ct[5], "$from $log_gecos: $command";
	&lockf($FILE);
}

#..................... Swap username & domain ...................
sub Invert {
	my $delim = shift(@_);
	my $newdelim = shift(@_);
	my @var = @_;
	my $restdelim = '>';	# And remember about user's specific flags, which are delimited by '>'
	my ($i, $us, $dom, $usdom, $rest);

	for ($i=0; $i < @var; $i++) {
		($usdom, $rest) = split (/$restdelim/, $var[$i]);
		($us, $dom) = split (/$delim/, $usdom);
		$var[$i] = $dom.$newdelim.$us.($rest ? $restdelim.$rest : "");
	}

	return @var;
}

##################################################################
##################################################################
###   i18n of messages - should be fairly easy to understand   ###
##################################################################
##################################################################

sub InitMessages {

##################################################################
###   en = English

push (@languages, 'en');

#-------------------------------
$msgtxt{'1en'} = <<_EOF_ ;
This is the Minimalist Mailing List Manager.

Commands may be either in subject of message (one command per message)
or in body (one or more commands, one per line). Batched processing starts
when subject either empty or contains command 'body' (without quotes) and
stops when either arrives command 'stop' or 'exit' (without quotes) or
gets 10 incorrect commands.

Supported commands are:

subscribe <list> [<email>] :
    Subscribe user to <list>. If <list> contains suffix '-writers', user
    will be able to write to this <list>, but will not receive messages
    from it.

unsubscribe <list> [<email>] :
    Unsubscribe user from <list>. Can be used with suffix '-writers' (see
    above description for subscribe)

auth <code> :
    Confirm command, used in response to subscription requests in some cases.
    This command isn't standalone, it must be used only in response to a
    request by Minimalist.

mode <list> <email> <mode> :
    Set mode for specified user on specified list. Allowed only for
    administrator. Mode can be (without quotes):
      * 'reader' - read-only access to the list for the user;
      * 'writer' - user can post messages to the list regardless of list's
                   status
      * 'usual' -  clear any two above mentioned modes
      * 'suspend' - suspend user subscription
      * 'resume' - resume previously suspended permission
      * 'maxsize <size>' - set maximum size (in bytes) of messages, which
                           user wants to receive
      * 'reset' - clear all modes for specified user

suspend <list> :
    Stop receiving of messages from specified mailing list

resume <list> :
    Restore receiving of messages from specified mailing list

maxsize <list> <size> :
    Set maximum size (in bytes) of messages, which user wants to receive

which [<email>] :
    Return list of lists to which user is subscribed

info [<list>] :
    Request information about all existing lists or about <list>

who <list> :
    Return the list of users subscribed to <list>

help :
    This message

Note, that commands with <email>, 'who' and 'mode' can only be used by
administrators (users identified in the 'mailfrom' authentication scheme or
who used a correct password - either global or local). Otherwise command will
be ignored. Password must be supplied in any header of message as fragment of
the header in the following format:

{pwd: list_password}

For example:

To: MML Discussion {pwd: password1235} <mml-general\@kiev.sovam.com>

This fragment, of course, will be removed from the header before sending message
to subscribers.
_EOF_

#-------------------------------
$msgtxt{'2en'} = "ERROR:\n\tYou";
$msgtxt{'3en'} = "are not subscribed to this list.\n\n".
		 "SOLUTION:\n\tSend a message to";
$msgtxt{'4en'} = "with a subject\n\tof 'help' (no quotes) for information about how to subscribe.\n\n".
		 "Your message follows:";
#-------------------------------
$msgtxt{'5en'} = "ERROR:\n\tYou";
$msgtxt{'5.1en'} = "are not allowed to write to this list.\n\nYour message follows:";
#-------------------------------
$msgtxt{'6en'} = "ERROR:\n\tMessage size is larger than maximum allowed (";
$msgtxt{'7en'} = "bytes ).\n\nSOLUTION:\n\tEither send a smaller message or split your message into multiple\n\tsmaller ones.\n\n".
		 "===========================================================================\n".
		 "Your message's header follows:";
#-------------------------------
$msgtxt{'8en'} = "\nERROR:\n\tThere is no authentication request with such code: ";
$msgtxt{'9en'} = "\n\nSOLUTION:\n\tResend your request to Minimalist.\n";

#-------------------------------
$msgtxt{'10en'} = "\nERROR:\n\tYou are not allowed to get subscription of other users.\n".
		  "\nSOLUTION:\n\tNone.";
#-------------------------------
$msgtxt{'11en'} = "\nCurrent subscription of user ";
#-------------------------------
$msgtxt{'12en'} = "\nERROR:\n\tThere is no such list";
$msgtxt{'13en'} = "here.\n\nSOLUTION:\n\tSend a message to";
$msgtxt{'14en'} = "with a subject\n\tof 'info' (no quotes) for a list of available mailing lists.\n";
#-------------------------------
$msgtxt{'15en'} = "\nERROR:\n\tYou aren't allowed to subscribe other people.\n".
		  "\nSOLUTION:\n\tNone.";
#-------------------------------
$msgtxt{'16en'} = "\nERROR:\n\tSorry, this list is closed for you.\n".
		  "\nSOLUTION:\n\tAre you unsure? Please, complain to ";
#-------------------------------
$msgtxt{'17en'} = "\nERROR:\n\tSorry, this list is mandatory for you.\n".
		  "\nSOLUTION:\n\tAre you unsure? Please, complain to ";
#-------------------------------
$msgtxt{'18en'} = "Your request";
$msgtxt{'19en'} = "must be authenticated. To accomplish this, send another request to";
$msgtxt{'20en'} = "(or just press 'Reply' in your mail reader)\nwith the following subject:";
$msgtxt{'21en'} = "This authentication request is valid for the next";
$msgtxt{'22en'} = "hours from now and then\nwill be discarded.\n";
#-------------------------------
$msgtxt{'23en'} = "\nHere is the available information about";
#-------------------------------
$msgtxt{'24en'} = "\nThese are the mailing lists available at";
#-------------------------------
$msgtxt{'25en'} = "\nUsers, subscribed to";
$msgtxt{'25.1en'} = "\nTotal: ";
#-------------------------------
$msgtxt{'26en'} = "\nERROR:\n\tYou are not allowed to get listing of subscribed users.";
#-------------------------------
$msgtxt{'27.0en'} = "Bad syntax or unknown instruction";
$msgtxt{'27en'} = "\nERROR:\n\t".$msgtxt{'27.0en'}.".\n\nSOLUTION:\n\n".$msgtxt{'1en'};
#-------------------------------
$msgtxt{'28en'} = "Sincerely, the Minimalist";
#-------------------------------
$msgtxt{'29en'} = "you already subscribed to";
#-------------------------------
$msgtxt{'30en'} = "there are already the maximum number of subscribers (";
#-------------------------------
$msgtxt{'31en'} = "you have subscribed to";
$msgtxt{'32en'} = "successfully.\n\nPlease note the following:\n";
#-------------------------------
$msgtxt{'33en'} = "you have not subscribed to";
$msgtxt{'34en'} = "due to the following reason";
$msgtxt{'35en'} = "If you have any comments or questions, please, send them to the list\nadministrator";
#-------------------------------
$msgtxt{'36en'} = "\nUser ";
$msgtxt{'37en'} = " has successfully unsubscribed.\n";
#-------------------------------
$msgtxt{'38en'} = "\nInternal error while processing your request; report sent to administrator.".
		  "\nPlease note, that subscription status for ";
$msgtxt{'38.1en'} = " not changed on ";
#-------------------------------
$msgtxt{'39en'} = " is not a registered member of this list.\n";
#-------------------------------
$msgtxt{'40en'} = "\nDear";
#-------------------------------
$msgtxt{'41en'} = "\nSettings for user ";
$msgtxt{'42en'} = " on list ";
$msgtxt{'43en'} = " there are no specific settings";
$msgtxt{'43.1en'} = " posts are allowed";
$msgtxt{'43.2en'} = " posts are not allowed";
$msgtxt{'43.3en'} = " subscription suspended";
$msgtxt{'43.4en'} = " maximum message size is ";
#-------------------------------
$msgtxt{'44en'} = "\nERROR:\n\tYou are not allowed to change settings of other people.\n".
		  "\nSOLUTION:\n\tNone.";
$msgtxt{'45en'} = "\nError: There were erors during minimalist execution. For more information email please maillist administrator ";
$msgtxt{'46en'} = "\nQuote next code in your email, please: ";

#
# Files with other translations, if available, can be found in
# distribution, in directory languages/ OR on Web, at
# http://www.mml.org.ua/languages/
#

push (@languages, 'ua');

##################################################################
###   ua = Ukrainian

#-------------------------------
$msgtxt{'1ua'} = <<_EOF_ ;
This is the Minimalist Mailing List Manager.

Команди можут знаходитись як в темі листа (одна команда на лист), так і в самому
листі (одна чи більше команд по одній в кожному рядку).  Обробка команд в тілі
листа виконується у випадку, якщо тема листа пуста, або містить команду 'body'
(без лапок). Закінчується обробка або у випадку досягнення команд 'stop' чи
'exit' (без лапок), або при досягненні 10 неправильних команд.

Підтримуються наступні команди:

subscribe <list> [<email>] :
    підписати користувача на список <list>. Якщо список <list> містить суфікс
    '-writers', користувач може писати в список <list>, але не буде отримувати
    повідомлення, надіслані до цього списку.

unsubscribe <list> [<email>] :
    відписатися від списку <list>. Може бути використаний із суфіксом '-writers'
    (опис цієї можливості див. вище)

auth <code> :
    підтверджуюча команда авторизації. Ця команда ніколи не використовується
    сама по собі, а тільки у відповідь на запит менеджера списку розсилки.

mode <list> <email> <mode> :
    встановити для вказаного підписника параметри надсилання та отримання
    повідомлень розсилки. Команда дозволена тільки адміністратору розсилки.
    Параметр 'mode' може приймати наступні значення (вказувати без лапок):
      * 'reader' - підписник не зможе публікувати повідомлення в розсилці;
      * 'writer' - підписник зможе публікувати повідомлення в розсилці навіть
                   якщо загальна конфігурація не дозволяє публікацію;
      * 'usual' - скинути будь-яке з двох вказаних вище налаштувань. Права
                  підписника будуть визначатися загальною конфігурацією
                  розсилки;
      * 'suspend' - призупинити отримання повідомлень користувачем;
      * 'resume' - відновити отримання повідомлень користувачем;
      * 'maxsize <size>' - встановити максимальний розмір повідомлень (в
                           байтах), що будуть надсилатися користувачам з
                           вказаної розсилки;
      * 'reset' - скинути всі параметри користувача.
    
suspend <list>:
    призупинити отримання повідомлень з розсилки

resume <list>:
    відновити припинене раніше командою 'suspend' отримання повідомлень з
    розсилки

maxsize <list> <size>:
    встановити максимальний розмір повідомлень (в байтах), які будуть
    надсилатися користувачам з зазначеної розсилки

which [<email>] :
    отримати перелік списків розсилки, на які підписаний користувач

info [<list>] :
    отримати додаткову інформацію про існуючі списки розсилки, чи про список
    <list>

who <list> :
    отримати список підписників на розсилку <list>

help :
    Повідомлення з описом команд і допомогою (це повідомлення)

Зверніть увагу, що <email> у всіх командах та команди 'who' і 'mode' можуть бути
використані тільки адміністраторами (користувачами, що пройшли аутентифікацію,
встановлену директовою auth розсилки, або глобальним паролем). Інакше команду
буде проігноровано. Пароль має бути вказаний, як фрагмент будь якого заголовка
листа в такому вигляді:

{pwd: list_password}

Наприклад:

To: MML Discussion {pwd: password1235} <mml-general\@example.com>

Цей фрагмент буде видалений перш ніж повідомлення буде надіслано підписникам
списка розсилки.
_EOF_

#-------------------------------
$msgtxt{'2ua'} = "Помилка:\n\tВи";
$msgtxt{'3ua'} = "не підписані на цю розсилку.\n\n".
		 "Вирішення проблеми:\n\tНадішліть повідомлення за адресою";
$msgtxt{'4ua'} = "з темою\n\t'help' (без лапок) для отримання інформації про те, як підписатися\n\n".
		 "Далі йде ваше повідомлення:";
#-------------------------------
$msgtxt{'5ua'} = "Помилка:\n\tВи не можете надсилати листи в цю розсилку.\n\n".
		 "Далі йде ваше повідомлення:";
#-------------------------------
$msgtxt{'6ua'} = "Помилка:\n\tДовжина вашого повідомлення більша за максимально допустиму (";
$msgtxt{'7ua'} = "байт).\n\nВирішення проблеми:\n\tАбо скоротіть ваше повідомлення, або розбийте його на\n\tдекілька менших частин та надішліть їх окремо.\n\n".
		 "===========================================================================\n".
		 "Далі йде ваше повідомлення:";
#-------------------------------
$msgtxt{'8ua'} = "\nПомилка:\n\tВ нашій базі немає запиту з таким кодом ідентифікації: ";
$msgtxt{'9ua'} = "\n\nВирішення проблеми:\n\tБудь ласка, надішліть ваш запит ще раз.\n";

#-------------------------------
$msgtxt{'10ua'} = "\nПомилка:\n\tВи не можете подивитися списки розсилок, на які підписані інші користувачі.\n".
		  "\nВирішення проблеми:\n\tВибачайте, ви не можете це змінити. :)";
#-------------------------------
$msgtxt{'11ua'} = "\nПоточний список підписки користувача на розсилки ";
#-------------------------------
$msgtxt{'12ua'} = "\nПомилка:\n\tТакого списка розсилки не існує";
$msgtxt{'13ua'} = ".\n\nВирішення проблеми:\n\tНадішліть повідомлення за адресою";
$msgtxt{'14ua'} = "з темою\n\t'info' (без лапок) для отримання списку доступних поштових розсилок.\n";
#-------------------------------
$msgtxt{'15ua'} = "\nПомилка:\n\tВи не можете в даній розсилці міняти статус інших користувачів.\n".
		  "\nВирішення проблеми:\n\tВибачте, ви не можете це змінити :)";
#-------------------------------
$msgtxt{'16ua'} = "\nПомилка:\n\tВибачте, ви не можете надіслати повідомлення в цей список розсилки.\n".
		  "\nВирішення проблеми:\n\tВи вважаєте, що це помилково? Повідомте про це за адресою ";
#-------------------------------
$msgtxt{'17ua'} = "\nПомилка:\n\tВибачте, ви не можете відписатися від цього списка розсилки.\n".
		  "\nВирішення проблеми:\n\tВи вважаєте, що це помилково? Повідомте про це за адресою ";
#-------------------------------
$msgtxt{'18ua'} = "Ваш запит";
$msgtxt{'19ua'} = "має бути авторизований. Для цього, будь ласка, наішліть інший запит за адресою";
$msgtxt{'20ua'} = "(або просто натисніть кнопку 'Відповісти' у вашій поштовій програмі)\nз таким заголовком:";
$msgtxt{'21ua'} = "Ви можете це зробити протягом";
$msgtxt{'22ua'} = "годин з моменту отримання цього листа. Як цей час збіжить запит буде видалено\n";
#-------------------------------
$msgtxt{'23ua'} = "\nНижче наведено всю доступну інформацію про";
#-------------------------------
$msgtxt{'24ua'} = "\nНаразі доступні наступні списки розсилки";
#-------------------------------
$msgtxt{'25ua'} = "\nСписок користувачів, підписаних на";
$msgtxt{'25.1ua'} = "\nВсього користувачів: ";
#-------------------------------
$msgtxt{'26ua'} = "\nПомилка:\n\tВи не можете отримати список користувачів, що підписані на цей список розсилки.";
#-------------------------------
$msgtxt{'27.0ua'} = "неправильно оформлено запит чи невірна команда";
$msgtxt{'27ua'} = "\nПомилка:\n\t".$msgtxt{'27.0ua'}.".\n\nВирішення проблеми:\n\n".$msgtxt{'1ua'};
#-------------------------------
$msgtxt{'28ua'} = "Sincerely, the Minimalist";
#-------------------------------
$msgtxt{'29ua'} = "Ви вже підписані на цю групу розсилки";
#-------------------------------
$msgtxt{'30ua'} = "шкода, ліміт підписників на цей список розсилки вичерпано (";
#-------------------------------
$msgtxt{'31ua'} = "ви успішно підписались на список";
$msgtxt{'32ua'} = ".\n\nБудь ласка, зверніть увагу на наступне:\n";
#-------------------------------
$msgtxt{'33ua'} = "ви не були підписані на список";
$msgtxt{'34ua'} = "з наступної причини";
$msgtxt{'35ua'} = "Якщо маєте якісь пітання чи пропозиції, будь ласка, надішліть їх адміністратору\nсписка розсилки";
#-------------------------------
$msgtxt{'36ua'} = "\nКористувач ";
$msgtxt{'37ua'} = " відписаний від розсилки.\n";
#-------------------------------
$msgtxt{'38ua'} = "\nПомилка обробки вашого запита; повідомлення спрямовано адміністратору.".
		  "\nБудь ласка, зверніть увагау, що підписка для ";
$msgtxt{'38.1ua'} = " не змінилась в списку розсилки ";
#-------------------------------
$msgtxt{'39ua'} = " не є зареєстрованим підписником даного списку розсилки.\n";
#-------------------------------
$msgtxt{'40ua'} = "\nШановний(-а)";
#-------------------------------
$msgtxt{'41ua'} = "\nСпецифічні параметри для підписника ";
$msgtxt{'42ua'} = " в розсилці ";
$msgtxt{'43ua'} = " не встановлені";
$msgtxt{'43.1ua'} = " публікація дозволена";
$msgtxt{'43.2ua'} = " публікація не дозволена";
$msgtxt{'43.3ua'} = " підписка призупинена";
$msgtxt{'43.4ua'} = " максимальний розмір повідомлення (байт): ";
#-------------------------------
$msgtxt{'44ua'} = "\nПОМИЛКА:\n\tВам не дозволено міняти параметри доступа інших підписників до розсилки.\n".
		  "\nВИРІШЕННЯ:\n\tВідсутнє.";
$msgtxt{'45ua'} = "\nПомилка: Під час виконання програми виникла помилка. За додатковою інформацією можна звернутися до адміністратора розсилки за адресою ";
$msgtxt{'46ua'} = "\nУ зверненні вкажіть, будь ласка, наступний код: ";
}

push (@languages, 'ru');

##################################################################
###   ru = Russian

#-------------------------------
$msgtxt{'1ru'} = <<_EOF_ ;
This is the Minimalist Mailing List Manager.

Команды могут быть указаны как в теме письма (одна команда на письмо), так
и в теле письма (одна и более команд, в одной в каждой строке). Обработка
команд в теле письма производится в том случае, если тема письма либо
пустая, либо содержит команду 'body' (без кавычек). Заканчивается обработка
либо в случае достижения команды 'stop' или 'exit' (без кавычек), либо по
получении 10 неправильных команд.

Поддерживаются следующие команды:

subscribe <list> [<email>] :
    подписать пользователя на список <list>. Если список <list> содержит
    суффикс '-writers', пользователь может писать в список <list>, но не
    будет получать сообщения, отправленные в этот список.

unsubscribe <list> [<email>] :
    отписаться от списка <list>. Может быть использован с суффиксом
    '-writers' (описание этой возможности см. выше)

auth <code> :
    подтверждающая команда авторизации. Эта команда никогда не
    используется сама по себе, а только в ответ на запрос менеджера списка
    рассылки.

mode <list> <email> <mode> :
    Установить для указанного подписчика параметры отправки и получения
    сообщений рассылки. Команда разрешена только для администратора
    рассылки.  Параметр 'mode' может принимать следующие значения
    (указывать без кавычек):
      * 'reader' - подписчик не сможет публиковать сообщения в рассылке;
      * 'writer' - подписчик сможет публиковать сообщения в рассылке даже
                   если общая конфигурация не разрешает публикацию;
      * 'usual' - сбросить любую из двух указанных выше настроек. Права
		  подписчика будут определяться общей конфигурацией
		  рассылки.
      * 'suspend' - приостановить получение сообщений пользователем
      * 'resume' - восстановить получение сообщений пользователем
      * 'maxsize <size>' - установить максимальный размер сообщений (в
			   байтах), которые будут отправляться
			   пользователю из указанной рассылки.
      * 'reset' - сбросить все параметры пользователя.
    
suspend <list>:
    приостановить получение сообщений из рассылки

resume <list>:
    восстановить прекращенное ранее командой 'suspend' получение сообщений
    из рассылки

maxsize <list> <size>:
    установить максимальный размер сообщений (в байтах), которые будут
    отправляться пользователю из указанной рассылки.

which [<email>] :
    получить перечень списков рассылки, на которые подписан пользователь

info [<list>] :
    получить дополнительную информацию о существующих списках рассылки или
    о списке <list>

who <list> :
    получить список подписчиков на рассылку <list>

help :
    Сообщение с помощью (это сообщение)

Обратите внимание, что <email> во всех командах и команды 'who' и 'mode'
могут быть использованы только администраторами (пользователями, прошедшими
аутентификацию, установленную директивой auth рассылки или глобальным
паролем). В противном случае команда будет проигнорирована. Пароль должен
быть указан, как фрагмент любого заголовка письма, в таком виде:

{pwd: list_password}

Например:

To: MML Discussion {pwd: password1235} <mml-general\@kiev.sovam.com>

Этот фрагмент будет удален из сообщения перед тем, как сообщение будет
отправлено подписчикам списка рассылки.
_EOF_

#-------------------------------
$msgtxt{'2ru'} = "Ошибка:\n\tВы";
$msgtxt{'3ru'} = "не подписаны на эту рассылку.\n\n".
		 "Решение проблемы:\n\tОтправьте сообщение по адресу";
$msgtxt{'4ru'} = "с темой\n\t'help' (без кавычек) для получения информации о том, как подписаться.\n\n".
		 "Далее идет Ваше сообщение:";
#-------------------------------
$msgtxt{'5ru'} = "Ошибка:\n\tВы не можете отправлять письма в данную рассылку.\n\n".
		 "Далее идет Ваше сообщение:";
#-------------------------------
$msgtxt{'6ru'} = "Ошибка:\n\tДлина Вашего сообшения больше максимально допустимой (";
$msgtxt{'7ru'} = "байт).\n\nРешение проблемы:\n\tЛибо сократите Ваше сообщение, либо пошлите его,\n\tразбив на несколько меньших частей.\n\n".
		 "===========================================================================\n".
		 "Далее идет Ваше сообщение:";
#-------------------------------
$msgtxt{'8ru'} = "\nОшибка:\n\tВ нашей базе нет запроса с таким кодом идентификации: ";
$msgtxt{'9ru'} = "\n\nРешение проблемы:\n\tПожалуйста, пошлите ваш запрос еще раз.\n";

#-------------------------------
$msgtxt{'10ru'} = "\nОшибка:\n\tВы не можете просмотреть списки рассылок, на которые подписаны другие пользователи.\n".
		  "\nРешение проблемы:\n\tИзвините, Вы не можете это изменить :)";
#-------------------------------
$msgtxt{'11ru'} = "\nТекущий список подписки пользователя на рассылки ";
#-------------------------------
$msgtxt{'12ru'} = "\nОшибка:\n\tТакого списка рассылки не существует";
$msgtxt{'13ru'} = ".\n\nРешение проблемы:\n\tПошлите сообщение по адресу";
$msgtxt{'14ru'} = "с темой\n\t'info' (без кавычек) для получения списка существующих почтовых рассылок.\n";
#-------------------------------
$msgtxt{'15ru'} = "\nОшибка:\n\tВы не можете в данной рассылке менять статус других пользователей.\n".
		  "\nРешение проблемы:\n\tИзвините, Вы не можете это изменить :)";
#-------------------------------
$msgtxt{'16ru'} = "\nОшибка:\n\tИзвините, вы не можете послать сообщение в этот список рассылки.\n".
		  "\nРешение проблемы:\n\tВы думаете, что это неверно? Сообщите об этом по адресу ";
#-------------------------------
$msgtxt{'17ru'} = "\nОшибка:\n\tИзвините, вы не можете отписаться от этого списка рассылки.\n".
		  "\nРешение проблемы:\n\tВы думаете, что это неверно? Сообщите об этом по адресу ";
#-------------------------------
$msgtxt{'18ru'} = "Ваш запрос";
$msgtxt{'19ru'} = "должен быть авторизирован. Для этого пожалуйста пошлите другой запрос по адресу";
$msgtxt{'20ru'} = "(или просто нажмите кнопку 'Reply' в вашей почтовой программе)\nс таким заголовком:";
$msgtxt{'21ru'} = "Вы можете это сделать в течение";
$msgtxt{'22ru'} = "часов с момента получения этого письма. По прошествии этого срока запрос\nбудет удален.\n";
#-------------------------------
$msgtxt{'23ru'} = "\nНиже приведена вся доступная информация о";
#-------------------------------
$msgtxt{'24ru'} = "\nВ данный момент доступны следующие списки рассылки";
#-------------------------------
$msgtxt{'25ru'} = "\nСписок пользователей, подписанных на";
$msgtxt{'25.1ru'} = "\nВсего пользователей: ";
#-------------------------------
$msgtxt{'26ru'} = "\nОшибка:\n\tВы не можете получить список пользователей, подписанных на данную рассылку.";
#-------------------------------
$msgtxt{'27.0ru'} = "неправильно оформлен запрос или неверная команда";
$msgtxt{'27ru'} = "\nОшибка:\n\t".$msgtxt{'27.0ru'}.".\n\nРешение проблемы:\n\n".$msgtxt{'1ru'};
#-------------------------------
$msgtxt{'28ru'} = "Sincerely, the Minimalist";
#-------------------------------
$msgtxt{'29ru'} = "Вы уже подписаны на группу рассылки";
#-------------------------------
$msgtxt{'30ru'} = "к сожалению, лимит подписчиков на данную рассылку исчерпан (";
#-------------------------------
$msgtxt{'31ru'} = "вы успешно подписались на список";
$msgtxt{'32ru'} = ".\n\nПожалуйста, обратите внимание на следующее:\n";
#-------------------------------
$msgtxt{'33ru'} = "вы не были подписаны на список";
$msgtxt{'34ru'} = "по следующей причине";
$msgtxt{'35ru'} = "Если у вас есть вопросы или предложения, пожалуйста, отправьте их администратору\nсписка рассылки";
#-------------------------------
$msgtxt{'36ru'} = "\nПользователь ";
$msgtxt{'37ru'} = " отписан от рассылки.\n";
#-------------------------------
$msgtxt{'38ru'} = "\nОшибка обработки Вашего запроса; сообщение направлено администратору.".
		  "\nПожалуйста, обратите внимание, что подписка для ";
$msgtxt{'38.1ru'} = " не изменилась в списке рассылки ";
#-------------------------------
$msgtxt{'39ru'} = " не является зарегистрированным подписчиком данного списка рассылки.\n";
#-------------------------------
$msgtxt{'40ru'} = "\nУважаемый(-ая)";
#-------------------------------
$msgtxt{'41ru'} = "\nСпецифические параметры для подписчика ";
$msgtxt{'42ru'} = " в рассылке ";
$msgtxt{'43ru'} = " не установлены";
$msgtxt{'43.1ru'} = " публикация разрешена";
$msgtxt{'43.2ru'} = " публикация не разрешена";
$msgtxt{'43.3ru'} = " подписка приостановлена";
$msgtxt{'43.4ru'} = " максимальный размер сообщения (байт): ";
#-------------------------------
$msgtxt{'44ru'} = "\nОШИБКА:\n\tВам не разрешено менять параметры доступа других подписчиков к рассылке.\n".
		  "\nРЕШЕНИЕ:\n\tОтсутствует.";
$msgtxt{'45ru'} = "\nОшибка: Во время выполнения программы произошла ошибка. За дополнительной информацией можно обратиться к администратору рассылки по адресу ";
$msgtxt{'46ru'} = "\nВ обращении укажите пожалуйста следующий код: ";
}
