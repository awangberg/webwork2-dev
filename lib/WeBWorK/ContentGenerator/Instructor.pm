################################################################################
# WeBWorK Online Homework Delivery System
# Copyright � 2000-2003 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork-modperl/lib/WeBWorK/ContentGenerator/Instructor.pm,v 1.32 2003/12/09 01:12:31 sh002i Exp $
# 
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package WeBWorK::ContentGenerator::Instructor;
use base qw(WeBWorK::ContentGenerator);

=head1 NAME

WeBWorK::ContentGenerator::Instructor - Abstract superclass for the Instructor
tools, providing useful utility functions.

=cut

use strict;
use warnings;
use CGI qw();
use WeBWorK::DB::Utils qw(global2user initializeUserProblem);

=head1 METHODS

=cut

################################################################################
# template escapes
################################################################################

# FIXME: remove this method, it does nothing.
#sub links {
# 	my $self = shift;
#	return $self->SUPER::links();
#}

################################################################################
# Primary assignment methods
################################################################################

=head2 Primary assignment methods

=over

=item assignSetToUser($userID, $GlobalSet)

Assigns the given set and all problems contained therein to the given user.
Silently fails if the set is already assigned to the user.

=cut

sub assignSetToUser {
	my ($self, $userID, $GlobalSet) = @_;
	my $setID = $GlobalSet->set_id;
	my $db = $self->{db};
	
	my $UserSet = $db->newUserSet;
	$UserSet->user_id($userID);
	$UserSet->set_id($setID);
	
	eval { $db->addUserSet($UserSet) };
	if ($@) {
		return if $@ =~ m/user set exists/;
		die $@;
	}
	
	# FIXME: this can be optimized with getAllGlobalProblems
	#foreach my $problemID ($db->listGlobalProblems($setID)) {
	#	my $GlobalProblem = $db->getGlobalProblem($setID, $problemID); # checked
		#if (not defined $GlobalProblem) {
		#	warn "GlobalProblem not found for set $setID problem $problemID, skipping";
		#	next;
		#}
	my @GlobalProblems = grep { defined $_ } $db->getAllGlobalProblems($setID);
	foreach my $GlobalProblem (@GlobalProblems) {
		$self->assignProblemToUser($userID, $GlobalProblem);
	}
}

=item unassignSetFromUser($userID, $setID, $problemID)

Unassigns the given set and all problems therein from the given user.

=cut

sub unassignSetFromUser {
	my ($self, $userID, $setID) = @_;
	my $db = $self->{db};
	
	$db->deleteUserSet($userID, $setID);
}

=item assignProblemToUser($userID, $GlobalProblem)

Assigns the given problem to the given user. Silently fails if the problem is
already assigned to the user.

=cut

sub assignProblemToUser {
	my ($self, $userID, $GlobalProblem) = @_;
	my $db = $self->{db};
	
	my $UserProblem = $db->newUserProblem;
	$UserProblem->user_id($userID);
	$UserProblem->set_id($GlobalProblem->set_id);
	$UserProblem->problem_id($GlobalProblem->problem_id);
	initializeUserProblem($UserProblem);
	
	eval { $db->addUserProblem($UserProblem) };
	if ($@) {
		return if $@ =~ m/user problem exists/;
		die $@;
	}
}

=item unassignProblemFromUser($userID, $setID, $problemID)

Unassigns the given problem from the given user.

=cut

sub unassignProblemFromUser {
	my ($self, $userID, $setID, $problemID) = @_;
	my $db = $self->{db};
	
	$db->deleteUserProblem($userID, $setID, $problemID);
}

=back

=cut

################################################################################
# Secondary set assignment methods
################################################################################

=head2 Secondary assignment methods

=over

=item assignSetToAllUsers($setID)

Assigns the set specified and all problems contained therein to all users in
the course. This is more efficient than repeatedly calling assignSetToUser().

=cut

sub assignSetToAllUsers {
	my ($self, $setID) = @_;
	my $db = $self->{db};
	
	my @userIDs = $db->listUsers;
	my @GlobalProblems = grep { defined $_ } $db->getAllGlobalProblems($setID);
	
	foreach my $userID (@userIDs) {
		my $UserSet = $db->newUserSet;
		$UserSet->user_id($userID);
		$UserSet->set_id($setID);
		eval { $db->addUserSet($UserSet) };
		if ($@) {
			next if $@ =~ m/user set exists/;
			die $@;
		}
		foreach my $GlobalProblem (@GlobalProblems) {
			$self->assignProblemToUser($userID, $GlobalProblem);
		}
	}
}

=item unassignSetFromAllUsers($setID)

Unassigns the specified sets and all problems contained therein from all users.

=cut

sub unassignSetFromAllUsers {
	my ($self, $setID) = @_;
	my $db = $self->{db};
	
	my @userIDs = $db->listSetUsers($setID);
	
	foreach my $userID (@userIDs) {
		$self->unassignSetFromUser($userID, $setID);
	}
}

=item assignAllSetsToUser($userID)

Assigns all sets in the course and all problems contained therein to the
specified user. This is more efficient than repeatedly calling
assignSetToUser().

=cut

sub assignAllSetsToUser {
	my ($self, $userID) = @_;
	my $db = $self->{db};
	
	# assign only sets that are not already assigned
	#my %userSetIDs = map { $_ => 1 } $db->listUserSets($userID);
	#my @globalSetIDs = grep { not exists $userSetIDs{$_} } $db->listGlobalSets;
	#my @GlobalSets = $db->getGlobalSets(@globalSetIDs);
	# FIXME: i don't think we need to do the above, since asignSetToUser fails
	# silently if a UserSet already exists. instead we do this:
	my @globalSetIDs = $db->listGlobalSets;
	my @GlobalSets = $db->getGlobalSets(@globalSetIDs);
	
	my $i = 0;
	foreach my $GlobalSet (@GlobalSets) {
		if (not defined $GlobalSet) {
			warn "record not found for global set $globalSetIDs[$i]";
		} else {
			$self->assignSetToUser($userID, $GlobalSet);
		}
		$i++;
	}
}

=item unassignAllSetsFromUser($userID)

Unassigns all sets and all problems contained therein from the specified user.

=cut

sub unassignAllSetsFromUser {
	my ($self, $userID) = @_;
	my $db = $self->{db};
	
	my @setIDs = $db->listUserSets($userID);
	
	foreach my $setID (@setIDs) {
		$self->unassignSetFromUser($userID, $setID);
	}
}

=back

=cut

################################################################################
# Utility assignment methods
################################################################################

=head2 Utility assignment methods

=over

=item assignSetsToUsers($setIDsRef, $userIDsRef)

Assign each of the given sets to each of the given users.

=cut

sub assignSetsToUsers {
	my ($self, $setIDsRef, $userIDsRef) = @_;
	my $db = $self->{db};
	
	my @setIDs = $setIDsRef;
	my @userIDs = $userIDsRef;
	my @GlobalSets = $db->getGlobalSets(@setIDs);
	
	foreach my $GlobalSet (@GlobalSets) {
		foreach my $userID (@userIDs) {
			$self->assignSetToUser($userID, $GlobalSet);
		}
	}
}

=item unassignSetsFromUsers($setIDsRef, $userIDsRef)

Unassign each of the given sets from each of the given users.

=cut

sub unassignSetsFromUsers {
	my ($self, $setIDsRef, $userIDsRef) = @_;
	my @setIDs = $setIDsRef;
	my @userIDs = $userIDsRef;
	
	foreach my $setID (@setIDs) {
		foreach my $userID (@userIDs) {
			$self->unassignSetFromUser($userID, $setID);
		}
	}
}

=item assignProblemToAllSetUsers($GlobalProblem)

Assigns the problem specified to all users to whom the problem's set is
assigned.

=cut

sub assignProblemToAllSetUsers {
	my ($self, $GlobalProblem) = @_;
	my $db = $self->{db};
	my $setID = $GlobalProblem->set_id;
	my @userIDs = $db->listSetUsers($setID);
	
	foreach my $userID (@userIDs) {
		$self->assignProblemToUser($userID, $GlobalProblem);
	}
}

=back

=cut

################################################################################
# Utility methods
################################################################################

=head2 Utility methods

=over

=cut

sub hiddenEditForUserFields {
	my ($self, @editForUser) = @_;
	my $return = "";
	foreach my $editUser (@editForUser) {
		$return .= CGI::input({type=>"hidden", name=>"editForUser", value=>$editUser});
	}
	
	return $return;
}

sub userCountMessage {
	my ($self, $count, $numUsers) = @_;
	
	my $message;
	if ($count == 0) {
		$message = CGI::em("no users");
	} elsif ($count == $numUsers) {
		$message = "all users";
	} elsif ($count == 1) {
		$message = "1 user";
	} elsif ($count > $numUsers || $count < 0) {
		$message = CGI::em("an impossible number of users: $count out of $numUsers");
	} else {
		$message = "$count users";
	}
	
	return $message;
}

sub read_dir {  # read a directory
	my $self      = shift;
	my $directory = shift;
	my $pattern   = shift;
	my @files = grep /$pattern/, WeBWorK::Utils::readDirectory($directory); 
	return sort @files;
}

sub read_scoring_file    { # used in SendMail and ....?
	my $self            = shift;
	my $fileName        = shift;
	my $delimiter       = shift;
	$delimiter          = ',' unless defined($delimiter);
	my $scoringDirectory= $self->{ce}->{courseDirs}->{scoring};
	my $filePath        = "$scoringDirectory/$fileName";  
        #       Takes a delimited file as a parameter and returns an
        #       associative array with the first field as the key.
        #       Blank lines are skipped. White space is removed
    my(@dbArray,$key,$dbString);
    my %assocArray = ();
    local(*FILE);
    if ($fileName eq 'None') {
    	# do nothing
    } elsif ( open(FILE, "$filePath")  )   {
		my $index=0;
		while (<FILE>){
			unless ($_ =~ /\S/)  {next;}               ## skip blank lines
			chomp;
			@{$dbArray[$index]} =$self->getRecord($_,$delimiter);
			$key    =$dbArray[$index][0];
			$assocArray{$key}=$dbArray[$index];
			$index++;
		}
		close(FILE);
     } else {
     	warn "Couldn't read file $filePath";
     }
     return \%assocArray;
}

=back

=cut

################################################################################
# Methods for listing various types of files
################################################################################

=head2 Methods for listing various types of files

=over

=cut

# list classlist files
sub getCSVList {
	my ($self) = @_;
	my $ce = $self->{ce};
	my $dir = $ce->{courseDirs}->{templates};
	return grep { not m/^\./ and m/\.lst$/ and -f "$dir/$_" } WeBWorK::Utils::readDirectory($dir);
}

sub getDefList {
	my ($self) = @_;
	my $ce = $self->{ce};
	my $dir = $ce->{courseDirs}->{templates};
	return $self->read_dir($dir, qr/.*\.def/);
}

=back

=cut

1;
