#!/usr/local/bin/perl -w 
use strict;
use warnings;

# Course manipulation functions for webwork webservices

package WebworkWebservice::CourseActions;

use WebworkWebservice;

use base qw(WebworkWebservice); 
use WeBWorK::Utils qw(runtime_use cryptPassword);
use WeBWorK::Utils::CourseManagement qw(addCourse);
use WeBWorK::Debug;

use Time::HiRes qw/gettimeofday/; # for log timestamp
use Date::Format; # for log timestamp

use Data::Dumper; # TODO remove


sub create {
	my ($self, $params) = @_;
	my $newcourse = $params->{'name'} . '-' . $params->{'section'};
	my $ce = WeBWorK::CourseEnvironment->new({
			webwork_dir => $self->{ce}->{webwork_dir},
			courseName => $newcourse
		});
	my $out = {};

	# make sure course actions are enabled
	if (!$ce->{webservices}{enableCourseActions}) {
		$out->{status} = "failure";
		$out->{message} = "Course actions disabled by configuration.";
		return $out
	}
	debug("XMLRPC course creation: " . Dumper($params));
	
	# declare params
	my @professors = ();
	my $dbLayout = $ce->{dbLayoutName};
	my %courseOptions = ( dbLayoutName => $dbLayout );
	my %dbOptions;
	my @users;
	my %optional_arguments;

	my $userClass = $ce->{dbLayouts}->{$dbLayout}->{user}->{record};
	my $passwordClass = $ce->{dbLayouts}->{$dbLayout}->{password}->{record};
	my $permissionClass = $ce->{dbLayouts}->{$dbLayout}->{permission}->{record};

	runtime_use($userClass);
	runtime_use($passwordClass);
	runtime_use($permissionClass);
	
	# configure users, only admin users
	# TODO admin user password
	my $adminName = $ce->{webservices}{courseActionsAdminUser};
	my $adminPass = $ce->{webservices}{courseActionsAdminPassword};
	my %record = ();
	$record{status} = $ce->{statuses}->{Enrolled}->{abbrevs}->[0];
	$record{password} = cryptPassword($adminPass);
	$record{permission} = $ce->{userRoles}{admin};
	$record{user_id} = $adminName;
	$record{last_name} = 'Administrator';

	my $User = $userClass->new(%record);
	my $PermissionLevel = $permissionClass->new(user_id => $adminName, permission => $record{permission});
	my $Password = $passwordClass->new(user_id => $adminName, password => $record{password});

	push @users, [ $User, $Password, $PermissionLevel ];
	
	# call
	eval {
		addCourse(
			courseID => $newcourse,
			ce => $ce,
			courseOptions => \%courseOptions,
			dbOptions => \%dbOptions,
			users => \@users,
			%optional_arguments,
		);
		addLog($ce, "New course created: " . $newcourse);
		$out->{status} = "success";
	} or do {
		$out->{status} = "failure";
		$out->{message} = $@;
	};
	
	return $out;
}

sub addUser {
	my ($self, $params) = @_;
	my $out = {};
	my $db = $self->{db};
	my $ce = $self->{ce};
	debug("XMLRPC Add User: " . Dumper($params));

	# make sure course actions are enabled
	if (!$ce->{webservices}{enableCourseActions}) {
		$out->{status} = "failure";
		$out->{message} = "Course actions disabled by configuration.";
		return $out
	}

	# Two scenarios
	# 1. New user
	# 2. Dropped user deciding to re-enrol

	my $olduser = $db->getUser($params->{id});
	if ($olduser) { 
		# a dropped user decided to re-enrol
		my $enrolled = $self->{ce}->{statuses}->{Enrolled}->{abbrevs}->[0];
		$olduser->status($enrolled);
		$db->putUser($olduser);
		addLog($ce, "User ". $olduser->user_id() . " re-enrolled in " . 
			$ce->{courseName});
		# TODO assign sets
		$out->{status} = 'success';
	}
	else {
		# a new user showed up
		my $ce = $self->{ce};
		my $id = $params->{'id'};
		
		# student record
		my $enrolled = $ce->{statuses}->{Enrolled}->{abbrevs}->[0];
		my $new_student = $db->{user}->{record}->new();
		$new_student->user_id($id);
		$new_student->first_name($params->{'firstname'});
		$new_student->last_name($params->{'lastname'});
		$new_student->status($enrolled);
		$new_student->student_id($params->{'studentid'});
		$new_student->email_address($params->{'email'});
		
		# password record
		my $cryptedpassword = "";
		if ($params->{'userpassword'}) {
			$cryptedpassword = cryptPassword($params->{'userpassword'});
		}
		elsif ($new_student->student_id()) {
			$cryptedpassword = cryptPassword($new_student->student_id());
		}
		my $password = $db->newPassword(user_id => $id);
		$password->password($cryptedpassword);
		
		# permission record
		my $permission = $params->{'permission'};
		debug($params->{'permission'});
		if (defined($ce->{userRoles}{$permission})) {
			$permission = $db->newPermissionLevel(
				user_id => $id, 
				permission => $ce->{userRoles}{$permission});
		}
		else {
			$permission = $db->newPermissionLevel(user_id => $id, 
				permission => $ce->{userRoles}{student});
		}

		# commit changes to db
		$out->{status} = 'success';
		eval{ $db->addUser($new_student); };
		if ($@) {
			$out->{status} = 'failure';
			$out->{message} = "Add user for $id failed!\n";
		}
		eval { $db->addPassword($password); };
		if ($@) {
			$out->{status} = 'failure';
			$out->{message} = "Add password for $id failed!\n";
		}
		eval { $db->addPermissionLevel($permission); };
		if ($@) {
			$out->{status} = 'failure';
			$out->{message} = "Add permission for $id failed!\n";
		}
		addLog($ce, "User ". $new_student->user_id() . " newly added in " . 
			$ce->{courseName});
		# TODO assign sets
	}

	return $out;
}

sub dropUser {
	my ($self, $params) = @_;
	my $db = $self->{db};
	my $ce = $self->{ce};
	my $out = {};
	debug("XMLRPC Drop User: " . Dumper($params));

	# make sure course actions are enabled
	if (!$ce->{webservices}{enableCourseActions}) {
		$out->{status} = "failure";
		$out->{message} = "Course actions disabled by configuration.";
		return $out
	}

	# Mark user as dropped
	my $drop = $self->{ce}->{statuses}->{Drop}->{abbrevs}->[0];
	my $person = $db->getUser($params->{'id'});
	if ($person)
	{
		$person->status($drop);
		$db->putUser($person);
		addLog($ce, "User ". $person->user_id() . " dropped from " . 
			$ce->{courseName});
		$out->{status} = 'success';
	}
	else
	{
		$out->{status} = 'failure';
		$out->{message} = 'Could not find user';
	}

	return $out;
}

sub addLog {
	my ($ce, $msg) = @_;
	if (!$ce->{webservices}{enableCourseActionsLog}) {
		return;
	}
	my ($sec, $msec) = gettimeofday;
	my $date = time2str("%a %b %d %H:%M:%S.$msec %Y", $sec);

	$msg = "[$date] $msg\n";

	my $logfile = $ce->{webservices}{courseActionsLogfile};
	if (open my $f, ">>", $logfile)
	{
		print $f $msg;
		close $f;
	}
	else
	{
		debug("Error, unable to open student updates log file '$logfile' in".
			"append mode: $!");
	}
	return;
}

1;
