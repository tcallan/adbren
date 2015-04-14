#!/usr/bin/perl -w
# Copyright (c) 2008, clip9 <clip9str@gmail.com>

# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.

# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

# AniDB Renamer.

use strict;
use warnings;
use File::Copy;
use File::Path;
use File::Find;
use File::HomeDir;
use Getopt::Long;
use Storable;
use Data::Dumper;
use Digest::CRC;
use Carp;

### DEFAULTS ###

# TODO: make the destination directory a config setting and get rid of these paths
my $format_presets = [
"/mnt/sumomo/data/anime/current/\%anime_name_romaji\%/\%anime_name_romaji\% - \%episode\%\%version\% [\%group_short\%]\%source\%[\%crc32\%].\%filetype\%",
"/mnt/sumomo/anime/finished/\%anime_name_romaji\%/\%anime_name_romaji\% - \%episode\%\%version\% [\%group_short\%]\%source\%[\%crc32\%].\%filetype\%",
"\%anime_name_english\%_\%episode\%\%version\%-\%group_short\%.\%filetype\%",
"\%anime_name_english\%_\%episode\%\%version\%_\%episode_name\%-\%group_short\%.\%filetype\%",
"\%anime_name_english\%_\%episode\%\%version\%_\%episode_name\%-\%group_short\%(\%crc32\%).\%filetype\%",
"\%anime_name_english\% - \%episode\% - \%episode_name\% - [\%group_short\%](\%crc32\%).\%filetype\%",
"[\%group_short\%] \%anime_name_english\% - \%episode\% - \%episode_name\% (\%crc32\%).\%filetype\%",
];

my $mylist        = 0;
my $norename      = 0;
my $noclean       = 0;
my $strict        = 0;
my $debug         = 0;
my $nocorrupt     = 0;
my $nolog         = 0;
my $noskip        = 0;
my $onlyhash      = 0;
my $format_preset = 0;
my $ping          = 0;
my $state         = -1;
my $logfile = File::Spec->catfile( File::HomeDir->my_data(), "adbren.log" );

my $format = undef;

my $config_file =
  File::Spec->catfile( File::HomeDir->my_data(), ".adbren.config" );

if ( not -f $config_file ) {
    configure($config_file);
}

my $config = retrieve($config_file)
  or die(
"There was a problem loading your configuration from $config_file, please delete it. ($!)"
  );

my $result = GetOptions(
    "mylist"    => \$mylist,
    "norename"  => \$norename,
    "noclean"   => \$noclean,
    "debug"     => \$debug,
    "format=s"  => \$format,
    "preset=i"  => \$format_preset,
    "onlyhash"  => \$onlyhash,
    "nocorrupt" => \$nocorrupt,
    "logfile=s" => \$logfile,
    "nolog"     => \$nolog,
    "noskip"    => \$noskip,
    "strict"    => \$strict,
    "ping"      => \$ping,
    "state=s"   => \$state,
);

if ( not defined $format ) {
    $format = $format_presets->[$format_preset];
}

my $a = AniDB::UDPClient->new(
    username  => $config->{username},
    password  => $config->{password},
    client    => "adbren",
    clientver => "6",
    debug     => $debug,
);

if ($ping) {
    print $a->ping(), "\n";
    exit(1);
}

if ( $state !~ m/[0-3]/ ) {
    if    ( $state eq "unknown" ) { $state = "0"; }
    elsif ( $state eq "hdd" )     { $state = "1"; }
    elsif ( $state eq "cd" )      { $state = "2"; }
    elsif ( $state eq "deleted" ) { $state = "3"; }
    else {
        croak "State " . $state . " is not supported.";
    }
}

my @files;
while ( ( my $file = shift ) ) {
    if ( -d $file ) {
        find(
            sub {
                if ( -f $_ ) { push @files, $File::Find::name; }
            },
            $file
        );
    }
    elsif ( -f $file ) {
        push @files, $file;
    }
    else {
        croak "$file not found, bailing.\n";
    }
}

if ( scalar @files < 1 ) {
    print_help();
    exit;
}

if ($onlyhash) {
    foreach my $file (@files) {
        my $ed2k = AniDB::UDPClient::ed2k_hash($file);
        my $size = -s $file;
        print "ed2k://|file|" . $file . "|" . $size . "|" . $ed2k . "|\n";
    }
    exit;
}

my $sent_logout = 0;
$SIG{'INT'} = 'CLEANUP';

sub CLEANUP {
    exit(1) if $sent_logout == 1;
    $sent_logout = 1;
    $a->logout();
    exit(1);
}

my $fileinfo;
my $newname;

foreach my $filepath (@files) {
    if ( not -e $filepath ) {
        print "$filepath Not found\n";
        next;
    }
    my $retry;
    my ( $volume, $directory, $filename ) = File::Spec->splitpath($filepath);
    print "File: $volume $directory, $filename" if $debug;
    if ( not $noskip and -f $logfile ) {
        open my $log, "<", $logfile;
        $/ = 1;
        my @raw_data = <$log>;
        my @matches = grep { $_ eq $filename } @raw_data;
        if ( scalar @matches > 0 ) {
            print "Skipped: $filename\n";
            next;
        }
    }
  RETRY:;
    $fileinfo = $a->file($filepath);
    if ( !defined $fileinfo ) {
        print $filename. ": Not Found in AniDB\n";
        if ( not $nocorrupt and not $filename =~ m/^_corrupt_/xmsi ) {
            move(
                $filepath,
                File::Spec->catpath(
                    $volume, $directory, '_corrupt_' . $filename
                )
            );
        }
        next;
    }
    $newname = $format;

    if (   not defined $fileinfo->{'anime_name_english'}
        or not defined $fileinfo->{'anime_name_romaji'} )
    {

        carp "Sanitycheck failed. Corrupt data from server?" if $retry <= 3;
        croak "Sanitycheck failed. Corrupt data from server?"  if $retry > 3;
        $retry++;
        sleep 5;
        goto RETRY;
    }

    if ( $fileinfo->{'anime_name_english'} eq "" ) {
        $fileinfo->{'anime_name_english'} = $fileinfo->{'anime_name_romaji'};
    }
    if ( $fileinfo->{'anime_name_romaji'} eq "" ) {
        $fileinfo->{'anime_name_romaji'} = $fileinfo->{'anime_name_english'};
    }
    # Manually calculate crc if anidb doesn't return one
    if ( $fileinfo->{'crc32'} eq "" ) {
        print "Calculating manual crc32 for $filename\n";
        my $crc = Digest::CRC->new(type=>"crc32");
        open(my $handle, $filepath);
        $crc->addfile(*$handle);
        close($handle);
        my $hash = $crc->hexdigest;
        $hash =~ tr/a-z/A-Z/;
        $fileinfo->{'crc32'} = $hash;
        print "Calculated $hash\n";
    }
    # Annotate files with non-standard sources
    my $src = $fileinfo->{'source'};
    if ( $src eq "HDTV" or $src eq "www" or $src eq "" ) {
        $src = "";
    } else {
        $src = "[" . $src . "]";
    }
    $fileinfo->{'source'} = $src;
    $newname =~ s/\%orginal_name\%/$filename/xmsig;
    while ( $newname =~ /\%([^\%]+)\%/ ) {
        my $key = $1;
        if ( defined $fileinfo->{$key} ) {
            $fileinfo->{$key} = substr $fileinfo->{$key}, 0, 180;
            if ( !$noclean ) {
                # TODO: custom renaming rules
                $fileinfo->{$key} =~ s/Nisekoi:/Nisekoi 2/g;
                $fileinfo->{$key} =~ s/[:%\/]//g;
                if ($strict) {
                    $fileinfo->{$key} =~ s/[^a-zA-Z0-9-]/_/g;
                }
                else {
                    # TODO: custom renaming rules
                    $fileinfo->{$key} =~ s/\*/Bleep/g;
                    $fileinfo->{$key} =~ s/[^a-zA-Z0-9-&!?()`',.~+\-; \[\]]/_/g;
                }
                $fileinfo->{$key} =~ s/[_]+/_/g;
            }
            $newname =~ s/\%$key\%/$fileinfo->{$key}/;
        }
        else {
            $newname =~ s/\%$key\%//;
        }
    }
    $newname =~ s/[_]+/_/g;
    $newname =~ s/_\./\./g;
    $newname =~ s/_-\./-/g;
    $newname =~ s/_\ /\ /g;
    $newname =~ s/\ _/\ /g;
    $newname =~ s/_\//\//g;
    my $newpath;
    my ( $fvol, $fdir, $ffile ) = File::Spec->splitpath($newname);

    if ( $fdir ne "" ) {
        $newpath = $newname;
    }
    else {
        $newpath = File::Spec->catpath( $volume, $directory, $newname );
    }
    print $filepath. ": Renamed to " . $newpath . "\n";
    if ($norename) {
    }
    else {

        if ( -e $newpath ) {
            print $filename. ": " . $newpath
              . " Already exists. Refusing to overwrite\n";
        }
        else {

            #This really dosen't make any sence.
            my ( $newvolume, $newdirectory, $newfile ) =
              File::Spec->splitpath($newname);

            print "Directory: $newdirectory\n" if $debug == 1;

            mkpath( File::Spec->catpath( $volume, $newdirectory, "" ) );
            move( $filepath, $newpath )
              or print( $filename. ": Rename: " . $! . "\n" );
            if ( not $nolog ) {
                open( my $log, ">>", $logfile ) or die $!;
                print $log "$newname\n";
                close $log;
            }
        }
    }
    if ($mylist) {
        $a->mylistadd( $fileinfo, $state );
    }
}
$a->logout();

sub print_help {
    print <<EOF;
adbren.pl [options] <file1\/dir1> [file2\/dir2] ...

Options:
	--format	Format. Default is preset 0
	--preset	Format preset number. See list below;
	--strict	Use stricter cleaning. Only allow [a-Z0-9._]
	--noclean	Do not clean values from API for format vars. 
           		(Don't remove special characters)
	--norename	Do not rename files. Just print the new names.
	--mylist	Add hashed files to mylist.
	--state		Set anime state; can be: hdd, cd or deleted.
	--onlyhash	Only print ed2k hashes. 
	--nocorrupt	Don't rename "corrupt" files. (Files not found in AniDB)
	--logfile	Log files renamed to this file. Default: ~\/adbren.log
			This log is used to avoid hashing files already processed.
	--noskip	Do not skip files found in the log.
	--nolog		Do not do any logging.
	--debug		Debug mode.

Format vars:
	\%fid\%, \%aid\%, \%eid\%, \%gid\%, \%lid\%, \%status\%, \%size\%, \%ed2k\%, 
	\%md5\%, \%sha1\%, \%crc32\%, \%lang_dub\%, \%lang_sub\%, \%quaility\%, \%source\%, 
	\%audio_codec\%, \%audio_bitrate\%, \%video_codec\%, \%video_bitrate\%,
	\%resolution\%, \%filetype\%, \%length\%, \%description\%, \%group\%, 
	\%group_short\%, \%episode\%, \%episode_name\%, \%episode_name_romaji\%,
	\%episode_name_kanii\%, \%episode_total\%, \%episode_last\%, \%anime_year\%,
	\%anime_type\%, \%anime_name_romaji\%, \%anime_name_kanji\%, 
	\%anime_name_english\%, \%anime_name_other\%, \%anime_name_short\%, 
	\%anime_synonyms\%, \%anime_category\%, \%version\%, \%censored\%,
	\%orginal_name\%

Note:
Directories on the command line are scanned recursivly. Files are renamed in the same directory.

Preset List:
EOF

    my $i = 0;
    foreach my $f ( @{$format_presets} ) {
        print "$i: $f\n";

        $i++;
    }

    exit;
}

sub configure {
    my ($config_file) = @_;
    print "Configuration file not found. Running first time configuration.\n";
    print "Configuration is stored in $config_file\n";
    print "Type your AniDB username followed by return:\n";
    my %hash;
    $hash{username} = <STDIN>;
    chomp( $hash{username} );
    print "Type your AniDB password followed by return:\n";
    $hash{password} = <STDIN>;
    chomp( $hash{password} );
    store \%hash, $config_file
      or die "There was a problem storing the configuration: $!";
    print
"Your adbren configuration is now stored in: $config_file. You can delete this file to rerun this configuration.\n";
    return;
}

package AniDB::UDPClient;
use strict;
no strict 'refs';
use warnings;
use IO::Socket;
use Digest::MD4;
use File::Spec;
use File::HomeDir ();
use Data::Dumper;
use Storable;
use Carp;

my $default_delay = 30;

#acodes:
use constant GROUP_NAME          => 0x00000001;
use constant GROUP_NAME_SHORT    => 0x00000002;
use constant EPISODE_NUMBER      => 0x00000100;
use constant EPISODE_NAME        => 0x00000200;
use constant EPISODE_NAME_ROMAJI => 0x00000400;
use constant EPISODE_NAME_KANII  => 0x00000800;
use constant EPISODE_TOTAL       => 0x00010000;
use constant EPISODE_LAST        => 0x00020000;
use constant ANIME_YEAR          => 0x00040000;
use constant ANIME_TYPE          => 0x00080000;
use constant ANIME_NAME_ROMAJI   => 0x00100000;
use constant ANIME_NAME_KANJI    => 0x00200000;
use constant ANIME_NAME_ENGLISH  => 0x00400000;
use constant ANIME_NAME_OTHER    => 0x00800000;
use constant ANIME_NAME_SHORT    => 0x01000000;
use constant ANIME_SYNONYMS      => 0x02000000;
use constant ANIME_CATAGORY      => 0x04000000;

#fcodes:
use constant AID           => 0x00000002;
use constant EID           => 0x00000004;
use constant GID           => 0x00000008;
use constant LID           => 0x00000010;
use constant STATUS        => 0x00000100;
use constant SIZE          => 0x00000200;
use constant ED2K          => 0x00000400;
use constant MD5           => 0x00000800;
use constant SHA1          => 0x00001000;
use constant CRC32         => 0x00002000;
use constant LANG_DUB      => 0x00010000;
use constant LANG_SUB      => 0x00020000;
use constant QUALITY       => 0x00040000;
use constant SOURCE        => 0x00080000;
use constant CODEC_AUDIO   => 0x00100000;
use constant BITRATE_AUDIO => 0x00200000;
use constant CODEC_VIDEO   => 0x00400000;
use constant BITRATE_VIDEO => 0x00800000;
use constant RESOLUTION    => 0x01000000;
use constant FILETYPE      => 0x02000000;
use constant LENGTH        => 0x04000000;
use constant DESCRIPTION   => 0x08000000;

#Status Codes
use constant STATUS_CRCOK  => 0x01;
use constant STATUS_CRCERR => 0x02;
use constant STATUS_ISV2   => 0x04;
use constant STATUS_ISV3   => 0x08;
use constant STATUS_ISV4   => 0x10;
use constant STATUS_ISV5   => 0x20;
use constant STATUS_UNC    => 0x40;
use constant STATUS_CEN    => 0x80;

use constant FILE_ENUM => qw/fid aid eid gid lid status_code size ed2k md5 sha1
  crc32 lang_dub lang_sub quaility source audio_codec audio_bitrate video_codec
  video_bitrate resolution filetype length description group group_short
  episode episode_name episode_name_romaji episode_name_kanii episode_total
  episode_last anime_year anime_type anime_name_romaji anime_name_kanji
  anime_name_english anime_name_other anime_name_short anime_synonyms
  anime_category/;

use constant ANIME_ENUM => qw/aid episodes episode_count special rating
  votes tmprating tmpvotes review_rating reviews year type romaji kanji
  english other short_name synonyms category/;

use subs 'debug';

sub new {
    my $class = shift;
    my $self  = bless {}, $class;
    my %args  = @_;
    foreach my $key ( keys %args ) {
        $self->{$key} = $args{$key};
    }

    # Quick debugging hack! Sorry ;)
    if ( $self->{debug} == 1 ) {
        *debug = sub {
            if (@_) {
                foreach my $x (@_) {
                    if ( ref $x eq 'ARRAY' || ref $x eq 'HASH' ) {
                        print STDERR Dumper($x);
                    }
                    else {
                        my $clean = $x;
                        $clean =~ s/[\n\r]*$//;
                        print STDERR $clean . " ";
                    }
                }
                print STDERR "\n";
            }
          }
    }
    else {
        *debug = sub { };
    }

    $self->{dbpath}     = File::HomeDir->my_data() . "/.adbren.db";
    $self->{dbpath_tmp} = File::HomeDir->my_data() . "/.adbren.db.tmp";
    $self->load_cache();
    $self->{delay}    = 0;
    $self->{hostname} = "api.anidb.info";
    $self->{port}     = 9000;
    $self->{handle}   = IO::Socket::INET->new( Proto => 'udp' ) or die($!);
    $self->{ipaddr}   = gethostbyname( $self->{hostname} )
      or die( "Gethostbyname(" . $self->{hostname} . "):" . $! );
    $self->{sockaddr} = sockaddr_in( $self->{port}, $self->{ipaddr} )
      or die($!);
    $self->{last_command} = 0;
    defined $self->{username}  or die "Username not defined!\n";
    defined $self->{password}  or die "Password not defined!\n";
    defined $self->{client}    or die "Client not defined!\n";
    defined $self->{clientver} or die "Clientver not defined!\n";
    $self->{state_file} =
      File::Spec->catfile( File::Spec->tmpdir(), "adbren_state.tmp" );

    return $self;
}

sub anime {
    my ( $self, $anime ) = @_;
    my %parameters;
    $parameters{s} = $self->{skey};
    if ( $anime =~ /\d+/ ) {
        $parameters{aid} = $anime;
    }
    else {
        $parameters{aname} = $anime;
    }
    my $msg = $self->_sendrecv( "ANIME", \%parameters );
    $msg =~ s/.*\n//im;
    my @f = split /\|/, $msg;
    my %animeinfo;
    if ( scalar @f > 0 ) {
        for ( my $i = 0 ; $i < ( scalar @f ) ; $i++ ) {
            $animeinfo{ (ANIME_ENUM)[$i] } = $f[$i];
        }
    }
    else {
        return undef;
    }
    debug "Animeinfo Hash:", \%animeinfo;
    return \%animeinfo;
}

sub file {
    my ( $self, $file ) = @_;
    my %parameters;
    $parameters{s} = $self->{skey};
    if ( -e $file ) {
        print $file. ": Hashing\n";
        $parameters{ed2k} = ed2k_hash($file);
        $parameters{size} = -s $file;
        if (    defined $self->{db}->{ $parameters{ed2k} }
            and defined $self->{db}->{ $parameters{ed2k} }->{fid} )
        {
            return $self->{db}->{ $parameters{ed2k} };
        }
    }
    else {
        $parameters{fid} = $file;
    }

    # the reason i'm not using -1 is that the api might change to include other
    # fields so the the ENUM might change.
    my $acode =
      GROUP_NAME | GROUP_NAME_SHORT | EPISODE_NUMBER | EPISODE_NAME |
      EPISODE_NAME_ROMAJI | EPISODE_NAME_KANII | EPISODE_TOTAL | EPISODE_LAST |
      ANIME_YEAR | ANIME_TYPE | ANIME_NAME_ROMAJI | ANIME_NAME_KANJI |
      ANIME_NAME_ENGLISH | ANIME_NAME_OTHER | ANIME_NAME_SHORT |
      ANIME_SYNONYMS | ANIME_CATAGORY;
    my $fcode =
      AID | EID | GID | LID | STATUS | SIZE | ED2K | MD5 | SHA1 | CRC32 |
      LANG_DUB | LANG_SUB | QUALITY | SOURCE | CODEC_AUDIO | BITRATE_AUDIO |
      CODEC_VIDEO | BITRATE_VIDEO | RESOLUTION | FILETYPE | LENGTH |
      DESCRIPTION;
    $parameters{acode} = $acode;
    $parameters{fcode} = $fcode;
    print $file. ": Getting info.\n";
    my $msg = $self->_sendrecv( "FILE", \%parameters, 1 );
    $msg =~ s/.*\n//im;
    my @f = split /\|/, $msg;
    my %fileinfo;

    if ( scalar @f > 0 ) {
        for ( my $i = 0 ; $i < ( scalar @f ) ; $i++ ) {
            $fileinfo{ (FILE_ENUM)[$i] } = $f[$i];
        }
        return $fileinfo if not defined $fileinfo{anime_name_short};
        $fileinfo{anime_name_short} =~ s/'/,/g;
        $fileinfo{anime_synonyms}   =~ s/'/,/g;
        $fileinfo{lang_sub}         =~ s/'/,/g;
        $fileinfo{lang_dub}         =~ s/'/,/g;
        $fileinfo{crc32}            =~ tr/a-z/A-Z/;
        $fileinfo{censored} = "cen"
          if ( $fileinfo{status_code} & STATUS_CEN );
        $fileinfo{censored} = "unc"
          if ( $fileinfo{status_code} & STATUS_UNC );

        if ( $fileinfo{status_code} & STATUS_ISV2 ) {
            $fileinfo{version} = "v2";
        }
        elsif ( $fileinfo{status_code} & STATUS_ISV3 ) {
            $fileinfo{version} = "v3";
        }
        elsif ( $fileinfo{status_code} & STATUS_ISV4 ) {
            $fileinfo{version} = "v4";
        }
        elsif ( $fileinfo{status_code} & STATUS_ISV5 ) {
            $fileinfo{version} = "v5";
        }
        $fileinfo{crcok}  = $fileinfo{status_code} & STATUS_CRCOK;
        $fileinfo{crcerr} = $fileinfo{status_code} & STATUS_CRCERR;
        $self->{db}->{ $parameters{ed2k} } = \%fileinfo;
        $self->save_cache();
        return \%fileinfo;
    }
    return undef;
}

sub load_cache {
    my ($self) = @_;
    return if not defined $self->{dbpath};
    if ( -e $self->{dbpath} ) {
        $self->{db} = retrieve( $self->{dbpath} ) or die $!;
        debug "Using cache: ", $self->{dbpath};
    }
    else {
        debug "Creating cache: ", $self->{dbpath};
        $self->{db} = {};
    }
    foreach my $key ( keys %{ $self->{db} } ) {
        next if $key eq 'session';
        if (   not defined $self->{db}->{$key}->{fid}
            or not defined $self->{db}->{$key}->{anime_name_short} )
        {
            delete $self->{db}->{$key};
        }
        elsif ( not $self->{db}->{$key}->{fid} =~ m/^\d+$/ ) {
            delete $self->{db}->{$key};
        }
    }
}

sub save_cache {
    my ($self) = @_;
    debug "Saving Cache.";
    store $self->{db}, $self->{dbpath_tmp} or die $!;
    rename $self->{dbpath_tmp}, $self->{dbpath} or die $!;
}

sub mylistadd {
    my ( $self, $file, $astate ) = @_;
    my %parameters;
    $parameters{s} = $self->{skey};
    if ( -e $file ) {
        print $file. ": Hashing.\n";
        $parameters{ed2k} = ed2k_hash($file);
        $parameters{size} = -s $file;
    }
    else {
        $parameters{fid} = $file->{fid};
    }
    if ( defined $astate and $astate > -1 ) {
        $parameters{state} = $state;
    }
    my $msg = $self->_sendrecv( "MYLISTADD", \%parameters, 1 );
    if ( $msg =~ /^2.*/ ) {
        print $file->{fid}. ": Added to mylist.\n";
    }
    else {
        carp $msg;
        return undef;
    }
    return 1;
}

sub login {
    my ($self) = @_;
    my $msg = "AUTH";
    my %parameters;

    $parameters{user}      = $self->{username};
    $parameters{pass}      = $self->{password};
    $parameters{protover}  = 3;
    $parameters{client}    = $self->{client};
    $parameters{clientver} = $self->{clientver};
    $parameters{nat}       = 1;
    $msg = $self->_sendrecv( $msg, \%parameters, 0 );

    if ( defined $msg
        && $msg =~ /20[0|1]\ ([a-zA-Z0-9]*)\ ([0-9\.\:]).*/ )
    {
        $self->{skey}   = $1;
        $self->{myaddr} = $2;
    }
    else {
        die "Login Failed: $msg\n";
    }
    return 1;
}

sub logout {
    my ($self) = @_;
    if ( $self->{skey} ) {
        return $self->_send( "LOGOUT skey=" . $self->{skey} );
    }
    else {
        return 0;
    }
}

sub notify {
    my ($self) = @_;
    return $self->_sendrecv( "NOTIFY", { skey => $self->{skey} } );
}

sub ping {
    my ($self) = @_;
    return $self->_sendrecv( "PING", {}, 0 );
}

# Takes the command string and a hash ref with the parameters.
# Sends and reads the reply. Tries up to 5 times.
sub _sendrecv {
    my ( $self, $command, $parameter_ref, $delay ) = @_;
    if (    not defined $self->{skey}
        and $command ne "AUTH"
        and $command ne "PING" )
    {
        $self->login();
        $parameter_ref->{s} = $self->{skey};
    }
    my $stat = 0;
    my $tag = "adbr-" . ( int( rand() * 10000 ) + 1 );
    $parameter_ref->{tag} = $tag;
    $delay = $default_delay if not defined $delay;
    while ( defined $delay and int( time - $self->{last_command} ) < $delay ) {
        $stat = $delay - ( time - $self->{last_command} );
        sleep($stat);
        debug "Delay: $stat\n";
    }

    my $msg_str = $command . " ";
    foreach my $k ( keys %{$parameter_ref} ) {
        $msg_str .= $k . "=" . $parameter_ref->{$k} . "&";
    }
    $msg_str =~ s/\&$//xmsi;
    $msg_str .= "\n";

    send( $self->{handle}, $msg_str, 0, $self->{sockaddr} )
      or croak( "Send: " . $! );
    $self->{last_command} = time;
    debug "-->", $msg_str;
    my $recvmsg;
    my $timer = 0;

    while ( !( $recvmsg = $self->_recv() ) ) {
        if ( $timer > 10 ) {
            carp "Timeout while wating for reply.\n";
            return undef;
        }
        $timer++;

        send( $self->{handle}, $msg_str, 0, $self->{sockaddr} )
          or croak( "Send: " . $! );
    }
    debug "<--", $recvmsg;
    if ( $recvmsg =~ m/(adbr-[\d]+)/xmsi ) {
        if ( $tag ne $1 ) {
            # Die if we don't get the expected response
            # Otherwise we'll continute to retry and usually end up banned
            # from the API
            croak
              "This is not the tag we are waiting for. Dying ($tag!= $1)\n";
            #return $self->_sendrecv( $command, $parameter_ref, $delay );
        }
        $recvmsg =~ s/adbr-[\d]+\ //xmsi;
    }
    if ( $recvmsg =~ /^501.*|^506.*/ ) {
        debug "Invalid session. Reauthing.";
        delete $self->{skey};
        $self->login();
        $parameter_ref->{s} = $self->{skey};
        return $self->_sendrecv( $command, $parameter_ref, $delay );
    }
    if ( $recvmsg =~ /^555/ ) {
        croak
"Banned. You should wait a few hours before retrying! Message:\n$recvmsg";
    }

    return $recvmsg;
}

sub _send {
    my ( $self, $msg ) = @_;
    send( $self->{handle}, $msg, 0, $self->{sockaddr} )
      or die( "Send: " . $! );
    debug "-->", $msg;
    sleep 1;
}

sub _recv {
    my ($self) = @_;
    my $rin = '';
    my $rout;
    vec( $rin, fileno( $self->{handle} ), 1 ) = 1;
    if ( select( $rout = $rin, undef, undef, 10.0 ) ) {
        my $msg;
        recv( $self->{handle}, $msg, 1500, 0 ) or craok( "Recv:" . $! );
        return $msg;
    }
    return undef;
}

sub ed2k_hash {
    my ($file) = @_;
    my $ctx    = Digest::MD4->new;
    my $ctx2   = Digest::MD4->new;
    my $buffer;
    open my $handle, "<", $file or die $!;
    binmode $handle;

    my $block  = 0;
    my $b      = 0;
    my $length = 0;

    while ( ( $length = read $handle, $buffer, 102400 ) ) {
        while ( $length < 102400 ) {
            my $missing = 102400 - $length;
            my $missing_buffer;
            my $missing_read = read $handle, $missing_buffer, $missing;
            $length += $missing_read;
            last if !$missing_read;
            $buffer .= $missing_buffer;
        }
        $ctx->add($buffer);
        $b++;

        if ( $b == 95 ) {
            $ctx2->add( $ctx->digest );
            $b = 0;
            $block++;
        }
    }
    close($handle);
    if ( $block == 0 ) {
        return $ctx->hexdigest;
    }
    if ( $b == 0 ) {
        return $ctx2->hexdigest;
    }
    $ctx2->add( $ctx->digest );
    return $ctx2->hexdigest;
}
