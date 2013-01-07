#!/usr/bin/perl

# -----------------------------------------------------------------------------
# Puppet execution wrapper that monitors for bug #13000
# ( http://projects.puppetlabs.com/issues/13000 )
#
# Patrick Viet <patrick.viet@gmail.com>
# https://github.com/patrickviet/puppet-tools/agent_run/puppet_agent_exec.pl
#
# Requires POE library - http://poe.perl.org - http://search.cpan.org/
# (apt-get install libpoe-perl in Ubuntu)
#
# This works on Linux and reads /proc but any patch to make it work elsewhere
# is welcome (ie. BSD, MacOS, ...)
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# The issue we are tackling looks like this:
# puppet gets blocked in this state
#
# \_ /bin/sh /usr/sbin/puppetsimple.sh
#   \_ /usr/bin/ruby1.8 /usr/bin/puppet agent --onetime --no-daemonize --verbose --detailed-exitcodes
#     \_ [sh] <defunct>
#
# So this 

use warnings;
use strict;
use POE qw(Wheel::Run);

# Matches and CMD
#my $puppetcmd = "/usr/sbin/puppetsimple.sh";
my $puppetcmd = "/usr/bin/puppet";
my @puppetopts = qw(agent --onetime --no-daemonize --verbose --detailed-exitcodes);
my $pmatch = "(puppet)";
my $maxzombie = 10;

# add ARGV
@puppetopts = (@puppetopts,@ARGV);

print "my process is $$\n";

POE::Session->create(
	inline_states => {
		_start => \&start,
		find_puppet_pid => \&find_puppet_pid,
		check_for_zombie => \&check_for_zombie,
		puppet_finish => \&puppet_finish,
		puppet_run => \&puppet_run,
		sigcld => \&sigcld,
		_stop => \&stop,

		stderr => \&stderr,
		stdout => \&stdout,
	}
);

sub start {

	my ($kernel,$heap) = @_[KERNEL,HEAP];

	# handle proper reap
	$heap->{runs_left} = 2;
	$kernel->yield('puppet_run');
}

sub stdout { print $_[ARG0]."\n"; }
sub stderr { print STDERR $_[ARG0]."\n"; }

sub puppet_run {

	my ($kernel,$heap) = @_[KERNEL,HEAP];

	if(!$heap->{runs_left}) {
		print "no more runs left...\n";
		return;
	}

	my $wheel = POE::Wheel::Run->new(
		Program => $puppetcmd,
		ProgramArgs => \@puppetopts,
		StdoutEvent => "stdout",
		StderrEvent => "stderr",
		CloseEvent => "puppet_finish",
	);

	$kernel->sig_child($wheel->PID, 'sigcld', $wheel->ID);
	$heap->{wheels}->{$wheel->ID} = $wheel;

	print "just launched child: ".$wheel->PID."\n";

	#$_[KERNEL]->yield('find_child');
	$kernel->delay_set('find_puppet_pid',5,$wheel->ID);

}


sub sigcld {
	my ($kernel, $heap, $sig, $pid, $exit_code, $wheel_id) = @_[KERNEL, HEAP, ARG0..ARG3];

	# see waitpid doc: to get the 'unix' value you must shift 8 bits.
	$exit_code = ($exit_code >> 8);

	print "got sigcld from pid $pid (exit: $exit_code)\n";
	delete $heap->{wheels}->{$wheel_id};

	$heap->{exit_code} = $exit_code;
}

sub stop {
	my $heap = $_[HEAP];
	if($heap->{exit_code} eq '0' or $heap->{exit_code} eq '2') {
		system("/usr/bin/touch /dev/shm/puppet_success_run");
	}

	open EXITCODE, ">/tmp/last_puppet_exit_code" or die $!;
	print EXITCODE $heap->{exit_code}."\n";
	close EXITCODE;


}

sub puppet_finish {
	print "puppet has finished...\n";
}

sub find_puppet_pid {
	my ($kernel,$heap,$wheel_id) = @_[KERNEL,HEAP,ARG0];
	my $pid = $heap->{wheels}->{$wheel_id}->PID;
	my $puppet_pid = find_child($pid,$pmatch,"");
	print "puppet pid is ".$puppet_pid."\n";
	$heap->{puppet_pid} = $puppet_pid;
	$kernel->yield('check_for_zombie',$wheel_id,$puppet_pid);
}

sub check_for_zombie {
	my ($kernel,$heap,$wheel_id,$puppet_pid) = @_[KERNEL,HEAP,ARG0,ARG1];
	#print "checking for zombie\n";
	return unless exists $heap->{wheels}->{$wheel_id};

	if (my $childpid = find_child($puppet_pid,"(sh)","Z")) {
		my $old = time() - (stat("/proc/$childpid/stat"))[10];
		if($old > $maxzombie) {
			# it's been a minute
			print "found a zombie $childpid\n";

			$heap->{wheels}->{$wheel_id}->kill(9);
			unlink "/var/lib/puppet/state/puppetdlock";
			$heap->{runs_left}--;
			$kernel->yield('puppet_run');

		}
	}

	#print "relaunch zombie check\n";
	$heap->{check_for_zombie} = $kernel->delay_set('check_for_zombie',10,$wheel_id,$puppet_pid);
}

sub find_child {
	my ($parentpid,$match,$state) = @_;

	opendir my $dh, "/proc";
	foreach my $pid (readdir($dh)) {
		next unless $pid =~ m/^[0-9]+$/ and (-d "/proc/$pid");

		open my $stfile, "/proc/$pid/stat";
		my $line = <$stfile>;
		close $stfile;

		my @sp = split(/\ /, $line);
		# see proc(5) : it goes: pid name state parentpid
		if($sp[3] eq $parentpid or $sp[0] eq $parentpid) {
			
			# this is my child process
			my $state_ok = 1;
			if($state) { if ($sp[2] ne $state) { $state_ok = 0 } }


			if($sp[1] =~ m/$match/ and $state_ok) {
				return $pid;
			} elsif($sp[0] ne $parentpid) {
				my $childsearch = find_child($pid,$match,$state);
				if($childsearch) { return $childsearch; }
			}

		}
	}

	return 0;
}

$poe_kernel->run;