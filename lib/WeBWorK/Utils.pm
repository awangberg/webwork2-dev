################################################################################
# WeBWorK Online Homework Delivery System
# Copyright � 2000-2007 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/lib/WeBWorK/Utils.pm,v 1.83 2009/07/12 23:48:00 gage Exp $
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

package WeBWorK::Utils;
use base qw(Exporter);

=head1 NAME

WeBWorK::Utils - useful utilities used by other WeBWorK modules.

=cut

use strict;
use warnings;
#use Apache::DB;
use DateTime;
use DateTime::TimeZone;
use Date::Parse;
use Date::Format;
use File::Copy;
use File::Spec;
use Time::Zone;
use MIME::Base64;
use Errno;
use File::Path qw(rmtree);
use Storable;
use Carp;

use constant MKDIR_ATTEMPTS => 10;

# "standard" WeBWorK date/time format (for set definition files):
#     %m/%d/%y at %I:%M%P
# where:
#     %m = month number, starting with 01
#     %d = numeric day of the month, with leading zeros (eg 01..31)
#     %Y = year (4 digits)
#     %I = hour, 12 hour clock, leading 0's)
#     %M = minute, leading 0's
#     %P = am or pm (Yes %p and %P are backwards :)
use constant DATE_FORMAT => "%m/%d/%Y at %I:%M%P %Z";

our @EXPORT    = ();
our @EXPORT_OK = qw(
	after
	before
	between
	constituency_hash
	cryptPassword
	decodeAnswers
	dequote
	encodeAnswers
	fisher_yates_shuffle
	formatDateTime
	has_aux_files
	intDateTime
	list2hash
	listFilesRecursive
	makeTempDirectory
	max
	not_blank
	parseDateTime
	path_is_subdir
	pretty_print_rh
	readDirectory
	readFile
	ref2string
	removeTempDirectory
	runtime_use
        sortAchievements
	sortByName
	surePathToFile
	textDateTime
	timeToSec
	trim_spaces
	undefstr
	writeCourseLog
	writeLog
	writeTimingLogEntry
);

=head1 FUNCTIONS

=cut

################################################################################
# Lowlevel thingies
################################################################################

# This is like use, except it happens at runtime. You have to quote the module name and put a
# comma after it if you're specifying an import list. Also, to specify an empty import list (as
# opposed to no import list) use an empty arrayref instead of an empty array.
# 
#   use Xyzzy;               =>    runtime_use "Xyzzy";
#   use Foo qw/pine elm/;    =>    runtime_use "Foo", qw/pine elm/;
#   use Foo::Bar ();         =>    runtime_use "Foo::Bar", [];

sub runtime_use($;@) {
	my ($module, @import_list) = @_;
	my $package = (caller)[0]; # import into caller's namespace
	
	my $import_string;
	if (@import_list == 1 and ref $import_list[0] eq "ARRAY" and @{$import_list[0]} == 0) {
		$import_string = "";
	} else {
		# \Q = quote metachars \E = end quoting
		$import_string = "import $module " . join(",", map { qq|"\Q$_\E"| } @import_list);
	}
	eval "package $package; require $module; $import_string";
	die $@ if $@;
}

#sub backtrace($) {
#	my ($style) = @_;
#	$style = "warn" unless $style;
#	my @bt = DB->backtrace;
#	shift @bt; # Remove "backtrace" from the backtrace;
#	if ($style eq "die") {
#		die join "\n", @bt;
#	} elsif ($style eq "warn") {
#		warn join "\n", @bt;
#	} elsif ($style eq "print") {
#		print join "\n", @bt;
#	} elsif ($style eq "return") {
#		return @bt;
#	}
#}

################################################################################
# Filesystem interaction
################################################################################

=head2 Filesystem interaction

=over

=cut

# Convert Windows and Mac (classic) line endings to UNIX line endings in a string.
# Windows uses CRLF, Mac uses CR, UNIX uses LF. (CR is ASCII 15, LF if ASCII 12)
sub force_eoln($) {
	my ($string) = @_;
	$string =~ s/\015\012?/\012/g;
	return $string;
}

sub readFile($) {
	my $fileName = shift;
	local $/ = undef; # slurp the whole thing into one string
	open my $dh, "<", $fileName
		or die "failed to read file $fileName: $!";
	my $result = <$dh>;
	close $dh;
	return force_eoln($result);
}

sub readDirectory($) {
	my $dirName = shift;
	opendir my $dh, $dirName
		or die "Failed to read directory $dirName: $!";
	my @result = readdir $dh;
	close $dh;
	return @result;
}

=item @matches = listFilesRecusive($dir, $match_qr, $prune_qr, $match_full, $prune_full)

Traverses the directory tree rooted at $dir, returning a list of files, named
pipes, and sockets matching the regular expression $match_qr. Directories
matching the regular expression $prune_qr are not visited.

$match_full and $prune_full are boolean values that indicate whether $match_qr
and $prune_qr, respectively, should be applied to the bare directory entry
(false) or to the path to the directory entry relative to $dir.

@matches is a list of paths relative to $dir.

=cut

sub listFilesRecursiveHelper($$$$$$);
sub listFilesRecursive($;$$$$) {
	my ($dir, $match_qr, $prune_qr, $match_full, $prune_full) = @_;
	return listFilesRecursiveHelper($dir, "", $match_qr, $prune_qr, $match_full, $prune_full);
}

sub listFilesRecursiveHelper($$$$$$) {
	my ($base_dir, $curr_dir, $match_qr, $prune_qr, $match_full, $prune_full) = @_;
	
	my $full_dir = "$base_dir/$curr_dir";
	
	my @dir_contents = readDirectory($full_dir);
	
	my @matches;
	
	foreach my $dir_entry (@dir_contents) {
		my $full_path = "$full_dir/$dir_entry";
		
		# determine whether the entry is a directory or a file, taking into account the 
		my $is_dir;
		my $is_file;
		if (-l $full_path) {
			my $link_target = "$full_dir/" . readlink $full_path;
			if ($link_target) {
				$is_dir = -d $link_target;
				$is_file = !$is_dir && -f $link_target || -p $link_target || -S $link_target;
			} else {
				warn "Couldn't resolve symlink $full_path: $!";
			}
		} else {
			$is_dir = -d $full_path;
			$is_file = !$is_dir && -f $full_path || -p $full_path || -S $full_path;
		}
		
		if ($is_dir) {
			# standard things to skip
			next if $dir_entry eq ".";
			next if $dir_entry eq "..";
			
			# skip unreadable directories (and broken symlinks, incidentally)
			unless (-r $full_path) {
				warn "Directory/symlink $full_path not readable";
				next;
			}
			
			# check $prune_qr
			my $subdir = ($curr_dir eq "") ? $dir_entry : "$curr_dir/$dir_entry";
			if (defined $prune_qr) {
				my $prune_string = $prune_full ? $subdir : $dir_entry;
				next if $prune_string =~ m/$prune_qr/;
			}
			
			# everything looks good, time to recurse!
			push @matches, listFilesRecursiveHelper($base_dir, $subdir, $match_qr, $prune_qr, $match_full, $prune_full);
		} elsif ($is_file) {
			my $file = ($curr_dir eq "") ? $dir_entry : "$curr_dir/$dir_entry";
			my $match_string = $match_full ? $file : $dir_entry;
			if (not defined $match_string or $match_string =~ m/$match_qr/) {
				push @matches, $file;
			}
		} else {
			# otherwise, it's a character device or a block device, and i don't
			# suppose we want anything to do with those ;-)
		}
	}
	
	return @matches;
}

# A very useful macro for making sure that all of the directories to a file have
# been constructed.
sub surePathToFile($$) {
	# constructs intermediate directories enroute to the file 
	# the input path must be the path relative to this starting directory
	my $start_directory = shift;
	my $path = shift;
	my $delim = "/"; 
	unless ($start_directory and $path ) {
		warn "missing directory<br> surePathToFile  start_directory   path ";
		return '';
	}
	# use the permissions/group on the start directory itself as a template
	my ($perms, $groupID) = (stat $start_directory)[2,5];
	# warn "&urePathToTmpFile: perms=$perms groupID=$groupID\n";
	
	# if the path starts with $start_directory (which is permitted but optional) remove this initial segment
	$path =~ s|^$start_directory|| if $path =~ m|^$start_directory|;

	
	# find the nodes on the given path
        my @nodes = split("$delim",$path);
	
	# create new path
	$path = $start_directory; #convertPath("$tmpDirectory");
	
	while (@nodes>1) {  # the last node is the file name
		$path = $path . shift (@nodes) . "/"; #convertPath($path . shift (@nodes) . "/");
		#FIXME  this make directory command may not be fool proof.
		unless (-e $path) {
			mkdir($path, $perms)
				or warn "Failed to create directory $path with start directory $start_directory ";
		}

	}
	
	$path = $path . shift(@nodes); #convertPath($path . shift(@nodes));
	return $path;
}

sub makeTempDirectory($$) {
	my ($parent, $basename) = @_;
	# Loop until we're able to create a directory, or it fails for some
	# reason other than there already being something there.
	my $triesRemaining = MKDIR_ATTEMPTS;
	my ($fullPath, $success);
	do {
		my $suffix = join "", map { ('A'..'Z','a'..'z','0'..'9')[int rand 62] } 1 .. 8;
		$fullPath = "$parent/$basename.$suffix";
		$success = mkdir $fullPath;
	} until ($success or not $!{EEXIST});
	die "Failed to create directory $fullPath: $!"
		unless $success;
	return $fullPath;
}

sub removeTempDirectory($) {
	my ($dir) = @_;
	rmtree($dir, 0, 0);
}

=item path_is_subdir($path, $dir, $allow_relative)

Ensures that $path refers to a location "inside" $dir. If $allow_relative is
true and $path is not absoulte, it is assumed to be relative to $dir.

The method of checking is rather rudimentary at the moment. First, upreferences
("..") are disallowed, in $path, then it is checked to make sure that some
prefix of it matches $dir.

If either of these checks fails, a false value is returned. Otherwise, a true
value is returned.

=cut

sub path_is_subdir($$;$) {
	my ($path, $dir, $allow_relative) = @_;
	
	unless ($path =~ /^\//) {
		if ($allow_relative) {
			$path = "$dir/$path";
		} else {
			return 0;
		}
	}
	
	$path = File::Spec->canonpath($path);
	$path .= "/" unless $path =~ m|/$|;
	return 0 if $path =~ m#(^\.\.$|^\.\./|/\.\./|/\.\.$)#;
	
	$dir = File::Spec->canonpath($dir);
	$dir .= "/" unless $dir =~ m|/$|;
	return 0 unless $path =~ m|^$dir|;
	
	return 1;
}

=back

=cut

################################################################################
# Date/time processing
################################################################################

=head2 Date/time processing

=over

=item $dateTime = parseDateTime($string, $display_tz)

Parses $string as a datetime. If $display_tz is given, $string is assumed to be
in that timezone. Otherwise, the server's timezone is used. The result,
$dateTime, is an integer UNIX datetime (epoch) in the server's timezone.

=cut

# This is a modified version of the subroutine of the same name from WeBWorK
# 1.9.05's scripts/FILE.pl (v1.13). It has been modified to understand time
# zones. The time zone specification must appear at the end of the string and be
# preceded by whitespace. The return value is a list consisting of the following
# elements:
# 
#     ($second, $minute, $hour, $day, $month, $year, $zone)
# 
# $second, $minute, $hour, $day, and $month are zero-indexed. $year is the
# number of years since 1900. $zone is a string (hopefully) representing the
# time zone.
# 
# Error handling has also been improved. Exceptions are now thrown for errors,
# and more information is given about the nature of errors.
# 
sub unformatDateAndTime {
	my ($string) = @_;
	my $orgString = $string;
	
	$string =~ s|^\s+||;
	$string =~ s|\s+$||;
	$string =~ s|at| at |i; ## OK if forget to enter spaces or use wrong case
	$string =~ s|AM| AM|i;	## OK if forget to enter spaces or use wrong case
	$string =~ s|PM| PM|i;	## OK if forget to enter spaces or use wrong case
	$string =~ s|,| at |;	## start translating old form of date/time to new form
	
	# case where the at is missing: MM/DD/YYYY at HH:MM AMPM ZONE
	unformatDateAndTime_error($orgString, "The 'at' appears to be missing.")
		if $string =~ m|^\s*[\/\d]+\s+[:\d]+|;
	
	my ($date, $at, $time, $AMPM, $TZ) = split /\s+/, $string;
	
	unformatDateAndTime_error($orgString, "The date and/or time appear to be missing.", $date, $time, $AMPM, $TZ)
		unless defined $date and defined $at and defined $time;
	
	# deal with military time
	unless ($time =~ /:/) {
		{  ##bare block for 'case" structure
			$time =~ /(\d\d)(\d\d)/;
			my $tmp_hour = $1;
			my $tmp_min = $2;
			if ($tmp_hour eq '00') {$time = "12:$tmp_min"; $AMPM = 'AM';last;}
			if ($tmp_hour eq '12') {$time = "12:$tmp_min"; $AMPM = 'PM';last;}
			if ($tmp_hour < 12) {$time = "$tmp_hour:$tmp_min"; $AMPM = 'AM';last;}
			if ($tmp_hour < 24) {
				$tmp_hour = $tmp_hour - 12;
				$time = "$tmp_hour:$tmp_min";
				$AMPM = 'PM';
			}
		}  ##end of bare block for 'case" structure

	}
	
	# default value for $AMPM
	$AMPM = "AM" unless defined $AMPM;
 	
	my ($mday, $mon, $year, $wday, $yday, $sec, $pm, $min, $hour);
	$sec=0;
	$time =~ /^([0-9]+)\s*\:\s*([0-9]*)/;
	$min=$2;
	$hour = $1;
	unformatDateAndTime_error($orgString, "Hour must be in the range [1,12].", $date, $time, $AMPM, $TZ)
		if $hour < 1 or $hour > 12;
	unformatDateAndTime_error($orgString, "Minute must be in the range [0-59].", $date, $time, $AMPM, $TZ)
		if $min < 0 or $min > 59;
	$pm = 0;
	$pm = 12 if ($AMPM =~/PM/ and $hour < 12);
	$hour += $pm;
	$hour = 0 if ($AMPM =~/AM/ and $hour == 12);
	$date =~  m|([0-9]+)\s*/\s*([0-9]+)/\s*([0-9]+)|;
	$mday =$2;
	$mon=($1-1);
	unformatDateAndTime_error($orgString, "Day must be in the range [1,31].", $date, $time, $AMPM, $TZ)
		if $mday < 1 or $mday > 31;
	unformatDateAndTime_error($orgString, "Month must be in the range [1,12].", $date, $time, $AMPM, $TZ)
		if $mon < 0 or $mon > 11;
	$year=$3;
	$wday="";
	$yday="";
	return ($sec, $min, $hour, $mday, $mon, $year, $TZ);
}

sub unformatDateAndTime_error {
	
	if (@_ > 2) {
		my ($orgString, $error, $date, $time, $AMPM, $TZ) = @_;
		$date = "(undefined)" unless defined $date;
		$time = "(undefined)" unless defined $time;
		$AMPM = "(undefined)" unless defined $AMPM;
		$TZ   = "(undefined)" unless defined $TZ;
		die "Incorrect date/time format \"$orgString\": $error\n",
			"Correct format is MM/DD/YY at HH:MM AMPM ZONE\n",
			"\tdate = $date\n",
			"\ttime = $time\n",
			"\tampm = $AMPM\n",
			"\tzone = $TZ\n";
	} else {
		my ($orgString, $error) = @_;
		die "Incorrect date/time format \"$orgString\": $error\n",
			"Correct format is MM/DD/YY at HH:MM AMPM ZONE\n";
	}
}

sub parseDateTime($;$) {
	my ($string, $display_tz) = @_;
	warn "time zone not defined".caller() unless defined($display_tz);
	$display_tz ||= "local";
	$display_tz = verify_timezone($display_tz);


	# use WeBWorK 1 date parsing routine
	my ($second, $minute, $hour, $day, $month, $year, $zone) = unformatDateAndTime($string);
	my $zone_str = defined $zone ? $zone : "UNDEF";
	#warn "\tunformatDateAndTime: $second $minute $hour $day $month $year $zone_str\n";
	
	# DateTime expects month 1-12, not 0-11
	$month++;
	
	# Do what Time::Local does to ambiguous years
	{
		my $ThisYear     = (localtime())[5]; # FIXME: should be relative to $string's timezone
		my $Breakpoint   = ($ThisYear + 50) % 100;
		my $NextCentury  = $ThisYear - $ThisYear % 100;
		   $NextCentury += 100 if $Breakpoint < 50;
		my $Century      = $NextCentury - 100;
		my $SecOff       = 0;
		
		if ($year >= 1000) {
			# leave alone
		} elsif ($year < 100 and $year >= 0) {
			$year += ($year > $Breakpoint) ? $Century : $NextCentury;
			$year += 1900;
		} else {
			$year += 1900;
		}
	}
	
	my $epoch;
	
	if (defined $zone and $zone ne "") {
		if (DateTime::TimeZone->is_valid_name($zone)) {
			#warn "\t\$zone is valid according to DateTime::TimeZone\n";
			
			my $dt = new DateTime(
				year      => $year,
				month     => $month,
				day       => $day,
				hour      => $hour,
				minute    => $minute,
				second    => $second,
				time_zone => $zone,
			);
			#warn "\t\$dt = ", $dt->strftime(DATE_FORMAT), "\n";
			
			$epoch = $dt->epoch;
			#warn "\t\$dt->epoch = $epoch\n";
		} else {
			#warn "\t\$zone is invalid according to DateTime::TimeZone, so we ask Time::Zone\n";
			
			# treat the date/time as UTC
			my $dt = new DateTime(
				year      => $year,
				month     => $month,
				day       => $day,
				hour      => $hour,
				minute    => $minute,
				second    => $second,
				time_zone => "UTC",
			);
			#warn "\t\$dt = ", $dt->strftime(DATE_FORMAT), "\n";
			
			# convert to an epoch value
			my $utc_epoch = $dt->epoch
				or die "Date/time '$string' not representable as an epoch. Get more bits!\n";
			#warn "\t\$utc_epoch = $utc_epoch\n";
			
			# get offset for supplied timezone and utc_epoch
			my $offset = tz_offset($zone, $utc_epoch) or die "Time zone '$zone' not recognized.\n";
			#warn "\t\$zone is valid according to Time::Zone (\$offset = $offset)\n";
			
			#$epoch = $utc_epoch + $offset;
			##warn "\t\$epoch = \$utc_epoch + \$offset = $epoch\n";
			
			$dt->subtract(seconds => $offset);
			#warn "\t\$dt - \$offset = ", $dt->strftime(DATE_FORMAT), "\n";
			
			$epoch = $dt->epoch;
			#warn "\t\$epoch = $epoch\n";
		}
	} else {
		#warn "\t\$zone not supplied, using \$display_tz\n";
		
		my $dt = new DateTime(
			year      => $year,
			month     => $month,
			day       => $day,
			hour      => $hour,
			minute    => $minute,
			second    => $second,
			time_zone => $display_tz,
		);
		#warn "\t\$dt = ", $dt->strftime(DATE_FORMAT), "\n";
		
		$epoch = $dt->epoch;
		#warn "\t\$epoch = $epoch\n";
	}
	
	return $epoch;
}


=item $string = formatDateTime($dateTime, $display_tz, $format_string, $locale)

Formats the UNIX datetime $dateTime in the custom format provided by $format_string.
If $format_string is not provided, the standard WeBWorK datetime format is used.
$dateTime is assumed to be in the server's time zone. If $display_tz is given,
the datetime is converted from the server's timezone to the timezone specified.
The available patterns for $format_string can be found in the documentation for
the perl DateTime package under the heading of strftime Patterns.
$dateTime is assumed to be in the server's time zone. If $display_tz is given,
the datetime is converted from the server's timezone to the timezone specified.
If $locale is provided, the string returned will be in the format of that locale,
which is useful for automatically translating things like days of the week and
month names.  If $locale is not provided, perl defaults to en_US.

=cut

sub formatDateTime($;$;$;$) {
	my ($dateTime, $display_tz, $format_string, $locale) = @_;
	warn "Utils::formatDateTime is not a method. ", join(" ",caller(2)) if ref($dateTime); # catch bad calls to Utils::formatDateTime
	warn "not defined formatDateTime('$dateTime', '$display_tz') ",join(" ",caller(2)) unless  $display_tz;
	$dateTime = $dateTime ||0;  # do our best to provide default values
	$display_tz ||= "local";    # do our best to provide default vaules
	$display_tz = verify_timezone($display_tz);
	
	$format_string ||= DATE_FORMAT; # If a format is not provided, use the default WeBWorK date format
	my $dt;
	if($locale) {
	    $dt = DateTime->from_epoch(epoch => $dateTime, time_zone => $display_tz, locale=>$locale);
	}
	else {
	    $dt = DateTime->from_epoch(epoch => $dateTime, time_zone => $display_tz);
	}
	#warn "\t\$dt = ", $dt->strftime(DATE_FORMAT), "\n";
	return $dt->strftime($format_string);
}


=item $string = textDateTime($string_or_dateTime)

Accepts a UNIX datetime or a formatted string, returns a formatted string.

=cut

sub textDateTime($) {
	return ($_[0] =~ m/^\d*$/) ? formatDateTime($_[0]) : $_[0];
}

=item $dateTIme = intDateTime($string_or_dateTime)

Accepts a UNIX datetime or a formatted string, returns a UNIX datetime.

=cut

sub intDateTime($) {
	return ($_[0] =~ m/^\d*$/) ?  $_[0] : parseDateTime($_[0]);
}

=item verify_timezone($display_tz)

If $display_tz is not a legal time zone then replace it with America/New_York and issue warning.



=cut

sub verify_timezone($) {
		my $display_tz = shift;
	    return $display_tz if (DateTime::TimeZone->is_valid_name($display_tz) );
	    warn qq! $display_tz is not a legal time zone name. Fix it on the Course Configuration page. 
	      <a href="http://en.wikipedia.org/wiki/List_of_zoneinfo_time_zones">View list of time zones.</a> \n!;
	    return "America/New_York";
}


=item $timeinsec = timeToSec($time)

Makes a stab at converting a time (with a possible unit) into a number of 
seconds.  

=cut

sub timeToSec($) {
    my $t = shift();
    if ( $t =~ /^(\d+)\s+(\S+)\s*$/ ) {
	my ( $val, $unit ) = ( $1, $2 );
	if ( $unit =~ /month/i || $unit =~ /mon/i ) {
	    $val *= 18144000;  # this assumes 30 days/month
	} elsif ( $unit =~ /week/i || $unit =~ /wk/i ) {
	    $val *= 604800;
	} elsif ( $unit =~ /day/i || $unit =~ /dy/i ) {
	    $val *= 86400;
	} elsif ( $unit =~ /hour/i || $unit =~ /hr/i ) {
	    $val *= 3600;
	} elsif ( $unit =~ /minute/i || $unit =~ /min/i ) {
	    $val *= 60;
	} elsif ( $unit =~ /second/i || $unit =~ /sec/i || $unit =~ /^s$/i ) {
	    # do nothing
	} else {
	    warn("Unrecognized time unit $unit.\nAssuming seconds.\n");
	}
	return $val;
    } elsif ( $t =~ /^(\d+)$/ ) {
	return $t;
    } else {
	warn("Unrecognized time interval: $t\n");
	return 0;
    }
}

=item before($time, $now)

True if $now is less than $time. If $now is not specified, the value of time()
is used.

=cut

sub before  { return (@_==2) ? $_[1] < $_[0] : time < $_[0] }

=item after($time, $now)

True if $now is greater than $time. If $now is not specified, the value of time()
is used.

=cut

sub after   { return (@_==2) ? $_[1] > $_[0] : time > $_[0] }

=item between($start, $end, $now)

True if $now is greater than or equal to $start and less than or equal to $end.
If $now is not specified, the value of time() is used.

=cut

sub between { my $t = (@_==3) ? $_[2] : time; return $t >= $_[0] && $t <= $_[1] }

=back

=cut

################################################################################
# Logging
################################################################################

sub writeLog($$@) {
	my ($ce, $facility, @message) = @_;
	unless ($ce->{webworkFiles}->{logs}->{$facility}) {
		warn "There is no log file for the $facility facility defined.\n";
		return;
	}
	my $logFile = $ce->{webworkFiles}->{logs}->{$facility};
	surePathToFile($ce->{webworkDirs}->{root}, $logFile);
	local *LOG;
	if (open LOG, ">>", $logFile) {
		print LOG "[", time2str("%a %b %d %H:%M:%S %Y", time), "] @message\n";
		close LOG;
	} else {
		warn "failed to open $logFile for writing: $!";
	}
}

sub writeCourseLog($$@) {
	my ($ce, $facility, @message) = @_;
	unless ($ce->{courseFiles}->{logs}->{$facility}) {
		warn "There is no course log file for the $facility facility defined.\n";
		return;
	}
	my $logFile = $ce->{courseFiles}->{logs}->{$facility};
	surePathToFile($ce->{courseDirs}->{root}, $logFile);
	local *LOG;
	if (open LOG, ">>", $logFile) {
		print LOG "[", time2str("%a %b %d %H:%M:%S %Y", time), "] @message\n";
		close LOG;
	} else {
		warn "failed to open $logFile for writing: $!";
	}
}

# $ce - a WeBWork::CourseEnvironment object
# $function - fully qualified function name
# $details - any information, do not use the characters '[' or ']'
# $beginEnd - the string "begin", "intermediate", or "end"
# use the intermediate step begun or completed for INTERMEDIATE
# use an empty string for $details when calling for END
# Information printed in format:
# [formatted date & time ] processID unixTime BeginEnd $function  $details
sub writeTimingLogEntry($$$$) {
	my ($ce, $function, $details, $beginEnd) = @_;
	$beginEnd = ($beginEnd eq "begin") ? ">" : ($beginEnd eq "end") ? "<" : "-";
	writeLog($ce, "timing", "$$ ".time." $beginEnd $function [$details]");
}

################################################################################
# Data munging
################################################################################
## Utility function to trim whitespace off the start and end of its input
sub trim_spaces {
	my $in = shift;
	return '' unless $in;  # skip blank spaces
	$in =~ s/^\s*(.*?)\s*$/$1/;
	return($in);
}
sub list2hash(@) {
	map {$_ => "0"} @_;
}

sub refBaseType($) {
	my $ref = shift;
	$ref =~ m/(\w+)\(/; # this might not be robust...
	return $1;
}

sub ref2string($;$);
sub ref2string($;$) {
	my $ref = shift;
	my $dontExpand = shift || {};
	my $refType = ref $ref;
	my $result;
	if ($refType and not $dontExpand->{$refType}) {
		my $baseType = refBaseType($ref);
		$result .= '<font size="1" color="grey">' . $refType;
		$result .= " ($baseType)" if $baseType and $refType ne $baseType;
		$result .= ":</font><br>";
		$result .= '<table border="1" cellpadding="2">';
		if ($baseType eq "HASH") {
			my %hash = %$ref;
			foreach (sort keys %hash) {
				$result .= '<tr valign="top">';
				$result .= "<td>$_</td>";
				$result .= "<td>" . ref2string($hash{$_}, $dontExpand) . "</td>";
				$result .= "</tr>";
			}
		} elsif ($baseType eq "ARRAY") {
			my @array = @$ref;
			# special case for Problem, Set, and User objects, which are defined
			# using lists and contain a @FIELDS package variable:
			no strict 'refs';
			my @FIELDS = eval { @{$refType."::FIELDS"} };
			use strict 'refs';
			undef @FIELDS unless scalar @FIELDS == scalar @array and not $@;
			foreach (0 .. $#array) {
				$result .= '<tr valign="top">';
				$result .= "<td>$_</td>";
				$result .= "<td>".$FIELDS[$_]."</td>" if @FIELDS;
				$result .= "<td>" . ref2string($array[$_], $dontExpand) . "</td>";
				$result .= "</tr>";
			}
		} elsif ($baseType eq "SCALAR") {
			my $scalar = $$ref;
			$result .= '<tr valign="top">';
			$result .= "<td>$scalar</td>";
			$result .= "</tr>";
		} else {
			# perhaps a coderef? in any case, i don't feel like dealing with it!
			$result .= '<tr valign="top">';
			$result .= "<td>$ref</td>";
			$result .= "</tr>";
		}
		$result .= "</table>"
	} else {
		$result .= defined $ref ? $ref : '<font color="red">undef</font>';
	}	
}
our $BASE64_ENCODED = 'base64_encoded:';  
#  use constant BASE64_ENCODED = 'base64_encoded;
#  was not evaluated in the matching and substitution
#  statements


sub decodeAnswers($) {
	my $serialized = shift;
	return unless defined $serialized and $serialized;
	my $array_ref = eval{ Storable::thaw($serialized) };
	if ($@) {
		# My hope is that this next warning is no longer needed since there are few legacy base64 days and the fix seems transparent.
		# warn "problem fetching answers -- possibly left over from base64 days. Not to worry -- press preview or submit and this will go away  permanently for this question.   $@";
		return ();
	} else {
		return @{$array_ref};
	}
}

sub encodeAnswers(\%\@) {
	my %hash = %{shift()};
	my @order = @{shift()};
	my @ordered_hash = ();
	foreach my $key (@order) {
		push @ordered_hash, $key, $hash{$key};
	}
	return Storable::freeze( \@ordered_hash);

}



sub max(@) {
	my $soFar;
	foreach my $item (@_) {
		$soFar = $item unless defined $soFar;
		if ($item > $soFar) {
			$soFar = $item;
		}
	}
	return defined $soFar ? $soFar : 0;
}

sub pretty_print_rh($) {
	my $rh = shift;
	foreach my $key (sort keys %{$rh})  {
		warn "  $key => ",$rh->{$key},"\n";
	}
}

sub cryptPassword($) {
	my ($clearPassword) = @_;
	my $salt = join("", ('.','/','0'..'9','A'..'Z','a'..'z')[rand 64, rand 64]);
	my $cryptPassword = crypt($clearPassword, $salt);
	return $cryptPassword;
}

# from the Perl Cookbook, first edition, page 25:
sub dequote($) {
	local $_ = shift;
	my ($white, $leader); # common whitespace and common leading string
	if (/^\s*(?:([^\w\s]+)(\s*).*\n)(?:\s*\1\2?.*\n)+$/) {
		($white, $leader) = ($2, quotemeta($1));
	} else {
		($white, $leader) = (/^(\s+)/, '');
	}
	s/^\s*?$leader(?:$white)?//gm;
	return $_;
}

sub undefstr($@) {
	map { defined $_ ? $_ : $_[0] } @_[1..$#_];
}


# shuffle an array in place
# Perl Cookbook, Recipe 4.17. Randomizing an Array
sub fisher_yates_shuffle {
	my $array = shift;
	my $i;
	for ($i = @$array; --$i; ) {
		my $j = int rand ($i+1);
		next if $i == $j;
		@$array[$i,$j] = @$array[$j,$i];
	}
}

sub constituency_hash {
	my $hash = {};
	@$hash{@_} = ();
	return $hash;
}

################################################################################
# Sorting
################################################################################

# p. 101, Camel, 3rd ed.
# The <=> and cmp operators return -1 if the left operand is less than the
# right operand, 0 if they are equal, and +1 if the left operand is greater
# than the right operand.
#
# FIXME: I've added the ability to do multiple field sorts, below; I'm 
#    leaving this code, commented out, in case there's a good reason to 
#    revert to this and do multiple field sorts differently.  -glr 2007/03/05
# sub sortByName($@) {
# 	my ($field, @items) = @_;
# 	return sort {
# 		my @aParts = split m/(?<=\D)(?=\d)|(?<=\d)(?=\D)/, defined $field ? $a->$field : $a;
# 		my @bParts = split m/(?<=\D)(?=\d)|(?<=\d)(?=\D)/, defined $field ? $b->$field : $b;
# 		while (@aParts and @bParts) {
# 			my $aPart = shift @aParts;
# 			my $bPart = shift @bParts;
# 			my $aNumeric = $aPart =~ m/^\d*$/;
# 			my $bNumeric = $bPart =~ m/^\d*$/;

# 			# numbers should come before words
# 			return -1 if     $aNumeric and not $bNumeric;
# 			return +1 if not $aNumeric and     $bNumeric;

# 			# both have the same type
# 			if ($aNumeric and $bNumeric) {
# 				next if $aPart == $bPart; # check next pair
# 				return $aPart <=> $bPart; # compare numerically
# 			} else {
# 				next if $aPart eq $bPart; # check next pair
# 				return $aPart cmp $bPart; # compare lexicographically
# 			}
# 		}
# 		return +1 if @aParts; # a has more sections, should go second
# 		return -1 if @bParts; # a had fewer sections, should go first
# 	} @items;
# }

sub sortByName($@) {
	my ($field, @items) = @_;

	my %itemsByIndex = ();
	if ( ref( $field ) eq 'ARRAY' ) {
		foreach my $item ( @items ) {
			my $key = '';
			foreach ( @$field ) {
		    		$key .= $item->$_;  # in this case we assume 
			}                           #    all entries in @$field
			$itemsByIndex{$key} = $item;  #  are defined.
	    	}
	} else {
	    %itemsByIndex = map {(defined $field)?$_->$field:$_ => $_} @items;
	}

	my @sKeys = sort {
		my @aParts = split m/(?<=\D)(?=\d)|(?<=\d)(?=\D)/, $a;
		my @bParts = split m/(?<=\D)(?=\d)|(?<=\d)(?=\D)/, $b;

		while (@aParts and @bParts) {
			my $aPart = shift @aParts;
			my $bPart = shift @bParts;
			my $aNumeric = $aPart =~ m/^\d*$/;
			my $bNumeric = $bPart =~ m/^\d*$/;

			# numbers should come before words
			return -1 if     $aNumeric and not $bNumeric;
			return +1 if not $aNumeric and     $bNumeric;

			# both have the same type
			if ($aNumeric and $bNumeric) {
				next if $aPart == $bPart; # check next pair
				return $aPart <=> $bPart; # compare numerically
			} else {
				next if $aPart eq $bPart; # check next pair
				return $aPart cmp $bPart; # compare lexicographically
			}
		}
		return +1 if @aParts; # a has more sections, should go second
		return -1 if @bParts; # a had fewer sections, should go first
	} (keys %itemsByIndex);

	return map{$itemsByIndex{$_}} @sKeys;
}


################################################################################
# Sort Achievements by category and id
################################################################################

sub sortAchievements {
	my @Achievements = @_;
	
	# First sort by achievement id

	@Achievements = sort {uc($a->{achievement_id}) cmp uc($b->{achievement_id})}  @Achievements;

	# Next sort by categoyr, but secret comes first and level last

	@Achievements = sort {
	    if ($a->{category} eq $b->{category}) {
		return 0; 
	    } elsif ($a->{category} eq "secret" or $b->{category} eq "level") {
		return -1;
	    } elsif ($a->{category} eq "level" or $b->{category} eq "secret") {
		return 1;
	    } else {
		return $a->{category} cmp $b->{category};
	    } } @Achievements;

	return @Achievements;
       
}

################################################################################
# Validate strings and labels
################################################################################

sub not_blank ($) {     # check that a string exists and is not blank
	my $str = shift;
	return( defined($str) and $str =~/\S/ );
}

###########################################################
    # If things have worked so far determine if the file might be accompanied by auxiliary files
    
    #
sub has_aux_files ($) { #  determine whether a question has auxiliary files
                        # a path ending in    foo/foo.pg  is assumed to contain auxilliary files
    my $path = shift;
    if ( not_blank($path) ) {
    	    my ($dir, $prob) = $path =~ m|([^/]+)/([^/]+)\.pg$|;  # must be a problem file ending in .pg
			return 1 if (defined($dir) and defined ($prob) and $dir eq $prob);
    } else {
    	warn "This subroutine cannot handle empty paths: |$path|",caller();
    }
    return 0;    # no aux files with this .pg file

}

1;
