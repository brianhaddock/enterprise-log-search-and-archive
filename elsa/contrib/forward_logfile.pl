#!/usr/bin/perl
use strict;
use Data::Dumper;
use IO::Handle;
use POSIX;
use Config::JSON;
use Getopt::Std;
use String::CRC32;
use Log::Log4perl;
use DBI;
use FindBin;
use JSON;
use IO::File;
use Digest::MD5;
use Time::HiRes;
use Archive::Zip;

# Include the directory this script is in
use lib $FindBin::Bin . '/../node';

my %Opts;
getopts('kc:f:', \%Opts);

unless ($Opts{f}){
	print('Usage: [ -k ] [ -c <config file> ] -f <file name>' . "\n" . '-k Keep original' . "\n");
	exit 1;
}

$| = 1;
my $pipes     = {};
my $Conf_file = $Opts{c} ? $Opts{c} : '/etc/elsa_node.conf';
my $Config_json = Config::JSON->new( $Conf_file );
my $Conf = $Config_json->{config}; # native hash is 10x faster than using Config::JSON->get()

# Setup logger
my $logdir = $Conf->{logdir};
my $debug_level = $Conf->{debug_level};
my $l4pconf = qq(
	log4perl.category.ELSA       = $debug_level, File, Screen
	log4perl.appender.File			 = Log::Log4perl::Appender::File
	log4perl.appender.File.filename  = $logdir/node.log
	log4perl.appender.File.syswrite = 1
	log4perl.appender.File.recreate = 1
	log4perl.appender.File.layout = Log::Log4perl::Layout::PatternLayout
	log4perl.appender.File.layout.ConversionPattern = * %p [%d] %F (%L) %M %P %m%n
	log4perl.filter.ScreenLevel               = Log::Log4perl::Filter::LevelRange
	log4perl.filter.ScreenLevel.LevelMin  = $debug_level
	log4perl.filter.ScreenLevel.LevelMax  = ERROR
	log4perl.filter.ScreenLevel.AcceptOnMatch = true
	log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
	log4perl.appender.Screen.Filter = ScreenLevel 
	log4perl.appender.Screen.stderr  = 1
	log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
	log4perl.appender.Screen.layout.ConversionPattern = * %p [%d] %F (%L) %M %P %m%n
);
Log::Log4perl::init( \$l4pconf ) or die("Unable to init logger\n");
my $Log = Log::Log4perl::get_logger("ELSA") or die("Unable to init logger\n");

my $filename = $Opts{f};
die('File not found') unless -f $filename;

# Calculate the MD5
my $md5 = new Digest::MD5;
my $fh = new IO::File($filename);
$md5->addfile($fh);
my $args = { md5 => $md5->hexdigest };
close($fh);

$fh = new IO::File($filename);
my $batch_counter = 0;
my ($start, $end) = (2**32, 0);
while (<$fh>){
	$batch_counter++;
	my (undef, $timestamp) = split(/\t/, $_);
	if ($timestamp and $timestamp < $start){
		$start = $timestamp;
	}
	if ($timestamp > $end){
		$end = $timestamp;
	}
}

$args->{batch_counter} = $batch_counter;
$args->{file} = $filename;
$args->{file_size} = -s $filename;
$args->{start} = $start;
$args->{end} = $end;
$args->{total_processed} = $batch_counter;
$args->{total_errors} = 0;
$args->{batch_time} = $Conf->{sphinx}->{index_interval};
$args->{compressed} = 1;
my $zip = Archive::Zip->new();
$args->{file} =~ /\/([^\/]+$)/;
my $shortfile = $1;
my $compressed_filename = $filename . '.zip';

my $time_start = Time::HiRes::time();
$zip->addFile($filename, $shortfile);
unless( $zip->writeToFileNamed($compressed_filename) == Archive::Zip::AZ_OK()){
	die('Unable to create compressed file ' . $compressed_filename);
}
my $taken = Time::HiRes::time() - $time_start;
$args->{compression_time} = $taken;
my $new_size = -s $compressed_filename;
$Log->trace('Compressed file to ' . $compressed_filename . ' in ' . $taken . ' at a rate of ' 
	. ($new_size/$taken) . ' bytes/sec and ratio of ' . ($args->{file_size} / $new_size)) if $taken;
$args->{file} = $compressed_filename;


# Move the buffer file and new program file to remote location
foreach my $dest_hash (@{ $Conf->{forwarding}->{destinations} }){	
	my $forwarder;
	if ($dest_hash->{method} eq 'cp'){
		require Forwarder::Copy;
		$forwarder = new Forwarder::Copy(log => $Log, conf => $Config_json, dir => $dest_hash->{dir});
	}
	elsif ($dest_hash->{method} eq 'scp'){
		require Forwarder::SSH;
		$forwarder = new Forwarder::SSH(log => $Log, conf => $Config_json, %{ $dest_hash });
	}
	elsif ($dest_hash->{method} eq 'url'){
		require Forwarder::URL;
		$forwarder = new Forwarder::URL(log => $Log, conf => $Config_json, %{ $dest_hash });
	}
	else {
		$Log->error('Invalid or no forward method given, unable to forward logs, args: ' . Dumper($dest_hash));
	}
	$forwarder->forward($args);
}

# Delete our forward zip file
unlink($compressed_filename);
if (not $Opts{k}){
	unlink($filename);
}
