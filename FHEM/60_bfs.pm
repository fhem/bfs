##############################################
# $Id: 60_bfs.pm 00000 2018-06-03 $$$
#
#  60_bfs.pm
#
#  2018 Markus Moises < vorname at nachname . de >
#  2020 Florian Asche <fhem@florian-asche.de>
#
#  This modul provides gamma radiation data from the BFS (Bundesamt 
#  für Strahlenschutz) Online Service
#
#  http://odlinfo.bfs.de/DE/themen/wo-stehen-die-sonden/messstellen-in-deutschland.html#standort
#
##############################################################################
#
# define <name> bfs <stationid>
#
##############################################################################

package main;

use strict;
use warnings;
use Time::Local;
use POSIX qw( strftime );
use JSON;
use Data::Dumper; #debugging
use Encode qw(encode_utf8);

##############################################################################


sub bfs_Initialize($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  $hash->{DefFn}        = "bfs_Define";
  $hash->{UndefFn}      = "bfs_Undefine";
  $hash->{GetFn}        = "bfs_Get";
  $hash->{AttrFn}       = "bfs_Attr";
  $hash->{DbLog_splitFn}= "bfs_DbLog_splitFn";
  $hash->{AttrList}     = "disable:0,1 ".
                          "userPassODL ".
                          "showTimeReadings:0,1 ".
                          $readingFnAttributes;
}

sub bfs_Define($$$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  my ($found, $dummy);

  return "syntax: define <name> bfs <stationid>" if(int(@a) != 3 );
  my $name = $hash->{NAME};

  $hash->{helper}{STATION} = $a[2];
  $hash->{helper}{INTERVAL} = 3600;
  $attr{$name}{stateFormat} = "radiation_total µSv/h" if( !defined($attr{$name}{stateFormat}));

  InternalTimer( gettimeofday() + 60, "bfs_GetUpdate", $hash, 0);


  #$hash->{STATE} = "Initialized";

  return undef;
}

sub bfs_Undefine($$) {
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};
  RemoveInternalTimer($hash);
  return undef;
}


sub bfs_Get($@) {
  my ($hash, @a) = @_;
  my $command = $a[1];
  my $parameter = $a[2] if(defined($a[2]));
  my $name = $hash->{NAME};


  my $usage = "Unknown argument $command, choose one of data:noArg";
  $usage .= " userPassODL:noArg" if(defined(AttrVal($name,"userPassODL",undef)));

  return $usage if $command eq '?';

  if($command eq "userPassODL")
  {
    return "No account data was found!" if(!defined(AttrVal($name,"userPassODL",undef)));
    return bfs_decrypt(AttrVal($name,"userPassODL",""));
  }
  
  RemoveInternalTimer($hash);

  if(AttrVal($name, "disable", 0) eq 1) {
    $hash->{STATE} = "disabled";
    return "bfs $name is disabled. Aborting...";
  }
  bfs_GetUpdate($hash);

  return undef;
}


sub bfs_GetUpdate($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  if(AttrVal($name, "disable", 0) eq 1) {
    $hash->{STATE} = "disabled";
    Log3 ($name, 2, "bfs $name is disabled, data update cancelled.");
    return undef;
  }

  RemoveInternalTimer($hash);

  return undef if(!defined(AttrVal($name,"userPassODL",undef)));
  bfs_GetUpdateODL($hash);
  
  return undef;
}

sub bfs_GetUpdateODL($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $station = $hash->{helper}{STATION};
  if(defined($station)){
  
  return undef if(!defined(AttrVal($name, "userPassODL", undef)));
  
  my $url="http://".bfs_decrypt(AttrVal($name, "userPassODL", ''))."@"."odlinfo2.bfs.de/daten/json/".$station."ct.json";
  Log3 ($name, 3, "Getting ODL data with login from URL: http://odlinfo2.bfs.de/daten/json/".$station."ct.json");  


    HttpUtils_NonblockingGet({
      url => $url,
      noshutdown => 1,
      timeout => 10,
      hash => $hash,
      callback => \&bfs_ParseODL,
    });
  }

  return undef;
}

sub bfs_ParseODL($$$) {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};


  if( $err )
  {
    Log3 $name, 1, "$name: URL error for ODL: ".$err;
    if($hash->{STATE} ne "error"){
      RemoveInternalTimer($hash, "bfs_GetUpdateODL");
      InternalTimer(int(gettimeofday()+600), "bfs_GetUpdateODL", $hash, 1);
    } else {
      RemoveInternalTimer($hash, "bfs_GetUpdateODL");
      InternalTimer(int(gettimeofday()+3600), "bfs_GetUpdateODL", $hash, 1);
    }
    $hash->{STATE} = "error";
    return undef;
  }
  elsif( $data !~ m/^{.*}$/ ){
    Log3 $name, 2, "$name: JSON error for ODL";
    my $nextupdate = int(gettimeofday())+600;
    if($hash->{STATE} ne "error"){
      RemoveInternalTimer($hash, "bfs_GetUpdateODL");
      InternalTimer($nextupdate, "bfs_GetUpdateODL", $hash, 1);
      $hash->{STATE} = "error";
    } else {
      RemoveInternalTimer($hash, "bfs_GetUpdateODL");
      InternalTimer(int(gettimeofday()+3600), "bfs_GetUpdateODL", $hash, 1);
    }
    return undef;  
  }
  
  my $json = eval { JSON->new->utf8(0)->decode($data) };
  if($@)
  {
    Log3 $name, 2, "$name: JSON evaluation error for ODL ".$@;
 
    if($hash->{STATE} ne "error"){
      RemoveInternalTimer($hash, "bfs_GetUpdateODL");
      InternalTimer(int(gettimeofday()+600), "bfs_GetUpdateODL", $hash, 1);
    } else {
      RemoveInternalTimer($hash, "bfs_GetUpdateODL");
      InternalTimer(int(gettimeofday()+3600), "bfs_GetUpdateODL", $hash, 1);
    }
    $hash->{STATE} = "error";
    return undef;  
  }

  my $stationdata = $json->{stamm};
  $hash->{RADIATION} = encode_utf8($stationdata->{ort});
  
  my $radiationdata = $json->{mw1h};

  my $i=0;
  my @t= (@{$radiationdata->{t}});
  my @mw= (@{$radiationdata->{mw}});
  my @ter= (@{$radiationdata->{ter}});
  my @cos= (@{$radiationdata->{cos}});
  my @ps= (@{$radiationdata->{ps}});

  my $lastupdate = ReadingsVal( $name, ".lastUpdateRadiation", 0);
  Log3 $name, 3, "$name: LastUpdate:".$lastupdate;
  my $timestamp = 0;
  my $received=0;
  
  foreach my $readingstime (@t) {
    Log3 $name, 3, "$name: DateTime:".$readingstime;
    my ($year,$mon,$day,$hour,$minute) = split(/[^\d]+/, $readingstime);
    $timestamp = timegm(0,$minute,$hour,$day,$mon-1,$year-1900);
    Log3 $name, 3, "$name: DateTime (timestamp): ".$timestamp;

    if($timestamp <= $lastupdate) {
      $i++;
      next;
    }
    my $readingmw = $mw[$i];
    my $readingcos = $cos[$i];
    my $readingter = $ter[$i];
    my $event = (int($ps[$i]) == 0 ? 1 : 0);

    readingsBeginUpdate($hash);
    $hash->{".updateTimestamp"} = FmtDateTime($timestamp);
    readingsBulkUpdate( $hash, "radiation_total", $mw[$i] );
    $hash->{CHANGETIME}[0] = FmtDateTime($timestamp);
    readingsEndUpdate($hash,$event);

    readingsBeginUpdate($hash);
    $hash->{".updateTimestamp"} = FmtDateTime($timestamp);
    readingsBulkUpdate( $hash, "radiation_cosmic", $cos[$i] );
    $hash->{CHANGETIME}[0] = FmtDateTime($timestamp);
    readingsEndUpdate($hash,$event);

    readingsBeginUpdate($hash);
    $hash->{".updateTimestamp"} = FmtDateTime($timestamp);
    readingsBulkUpdate( $hash, "radiation_terrestrial", $ter[$i] );
    $hash->{CHANGETIME}[0] = FmtDateTime($timestamp);
    readingsEndUpdate($hash,$event);

    Log3 $name, 4, FmtDateTime($timestamp)." ($readingstime UTC / $timestamp): total $readingmw µSv/h, cosmic $readingcos µSv/h, terrestrial $readingter µSv/h";

    $i++;
    $received++;
  }
  readingsSingleUpdate( $hash, ".lastUpdateRadiation", $timestamp, 0 ) if($received > 0);
  readingsSingleUpdate( $hash, "lastUpdateRadiation", FmtDateTime($timestamp), 0 ) if($received > 0 && AttrVal($name, "showTimeReadings", 0) eq 1);

  Log3 $name, 2, "Received $received values for radiation";
  Log3 $name, 5, "JSON data for radiation\n".Dumper($json);


  my $nextupdate = gettimeofday()+$hash->{helper}{INTERVAL};
    RemoveInternalTimer($hash, "bfs_GetUpdate");
  InternalTimer($nextupdate, "bfs_GetUpdate", $hash, 1);

  return undef;
}

sub bfs_encrypt($)
{
  my ($decoded) = @_;
  my $key = getUniqueId();
  my $encoded;

  return $decoded if( $decoded =~ /crypt:/ );

  for my $char (split //, $decoded) {
    my $encode = chop($key);
    $encoded .= sprintf("%.2x",ord($char)^ord($encode));
    $key = $encode.$key;
  }

  return 'crypt:'.$encoded;
}

sub bfs_decrypt($)
{
  my ($encoded) = @_;
  my $key = getUniqueId();
  my $decoded;

  return $encoded if( $encoded !~ /crypt:/ );
  
  $encoded = $1 if( $encoded =~ /crypt:(.*)/ );

  for my $char (map { pack('C', hex($_)) } ($encoded =~ /(..)/g)) {
    my $decode = chop($key);
    $decoded .= chr(ord($char)^ord($decode));
    $key = $decode.$key;
  }

  return $decoded;
}

sub bfs_Attr(@)
{
  my ($cmd, $device, $attribName, $attribVal) = @_;
  my $hash = $defs{$device};

  $attribVal = "" if (!defined($attribVal));

  if($cmd eq "set" && $attribName eq "userPassODL")
  {
    $attr{$device}{"userPassODL"} = bfs_encrypt($attribVal);
  }
  
  return undef;
}

sub bfs_DbLog_splitFn($) {
  my ($event) = @_;
  my ($reading, $value, $unit) = "";

  my @parts = split(/ /,$event,3);
  $reading = $parts[0];
  $reading =~ tr/://d;
  $value = $parts[1];
  $unit = "µSv/h";

  Log3 "dbsplit", 5, "bfs dbsplit: ".$event."\n$reading: $value $unit";

  return ($reading, $value, $unit);
}

##########################

1;

=pod
=item device
=item summary Module to fetch gamma radiation data from Bundesamt für Strahlenschutz online Service
=begin html

<a name="bfs"></a>
<h3>bfs</h3>
<ul>
  This modul provides gamma radiation data from Bundesamt für Strahlenschutz online Service.<br/>
  <br/><br/>
  Disclaimer:<br/>
  Users are responsible for compliance with the respective terms of service, data protection and copyright laws.<br/><br/>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; bfs &lt;stationid&gt;</code>
    <br>
    Example: <code>define airdata bfs 057540080</code>
    <br>&nbsp;
    <li><code>stationid</code>
      <br>
      BfS station id to be used for getting radiation data, station id see <br/>
      <a href="http://odlinfo.bfs.de/DE/themen/wo-stehen-die-sonden/messstellen-in-deutschland.html#standort">odlinfo.bfs.de/messstellen</a>
    </li><br>
  </ul>
  <br>
  <b>Get</b>
   <ul>
      <li><code>data</code>
      <br>
      Manually trigger data update
      </li><br>
  </ul>
  <br>
  <b>Readings</b>
    <ul>
      <li><code>radiation_total</code>
      <br>
      Total ambient dose rate in µSv/h, 1h median value<br/>
      </li><br>
      <li><code>radiation_cosmic</code>
      <br>
      Cosmic part of ambient dose rate in µSv/h, 1h median value<br/>
      </li><br>
      <li><code>radiation_terrestrial</code>
      <br>
      Terrestrial part of ambient dose rate in µSv/h, 1h median value<br/>
      </li><br>
      <li><code>lastUpdateXX</code>
      <br>
      Last update time for pollutant XX (only if enabled through showTimeReadings)<br/>
      </li><br>
    </ul>
  <br>
   <b>Attributes</b>
   <ul>
      <li><code>disable</code>
         <br>
         Disables the module
      </li><br>
      <li><code>showTimeReadings</code>
         <br>
         Create visible readings for last update times
      </li><br>
      <li><code>userPassODL</code>
         <br>
         Username and password from BfS, enter it in the format <i>username:password</i><br/>
         You can apply for a key here: <a href="http://odlinfo.bfs.de/DE/service/datenschnittstelle.html">odlinfo.bfs.de/service/datenschnittstelle</a>
      </li><br>
  </ul>
</ul>

=end html
=cut
