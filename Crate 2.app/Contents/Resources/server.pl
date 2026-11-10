use strict; use warnings; use IO::Socket::INET; use IO::Select; use JSON::PP; use File::Path 'make_path';
my($port,$res)=@ARGV; my $home=$ENV{HOME};
my $cache="$home/Library/Caches/Crate"; my $sup="$home/Library/Application Support/Crate";
make_path("$cache/art",$sup); $SIG{CHLD}='IGNORE'; $SIG{PIPE}='IGNORE';
my $srv=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>$port,Listen=>30,ReuseAddr=>1,Proto=>'tcp') or die "port";
my $sel=IO::Select->new($srv); my($last,$seen,$ui)=(time,0,0);
sub slurp{my $f=shift; open(my $h,'<:raw',$f) or return undef; local $/; my $d=<$h>; close $h; $d}
sub spit{my($f,$d)=@_; utf8::encode($d) if utf8::is_utf8($d); open(my $h,'>:raw',$f) or return; print $h $d; close $h}
sub resp{my($c,$code,$type,$body)=@_; my $cc=$type=~/^image/?'max-age=86400':'no-store';
  utf8::encode($body) if utf8::is_utf8($body);
  print $c "HTTP/1.1 $code\r\nContent-Type: $type\r\nContent-Length: ".length($body)."\r\nCache-Control: $cc\r\nConnection: close\r\n\r\n$body"}
sub osa{my($lang,$script,@a)=@_; my $sock=IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>47824,Proto=>'tcp',Timeout=>120) or return "ERROR: Crate automation bridge unavailable: $!";
  $sock->autoflush(1); print $sock encode_json({lang=>$lang,script=>$script,args=>\@a})."\n" or return "ERROR: Could not contact Crate automation bridge";
  my $line=<$sock>; close $sock; return "ERROR: Crate automation bridge returned no response" unless defined $line;
  my $result=eval{decode_json($line)}; return "ERROR: Invalid response from Crate automation bridge" if $@ || ref($result) ne 'HASH';
  return "ERROR: $result->{error}" if $result->{error}; return $result->{result}//''}
my $LIB=<<'AS';
on run argv
 tell application "Music"
  set trackRows to properties of every track of library playlist 1
 end tell
 set trackJSON to ""
 tell application "Music"
 repeat with trackRef in trackRows
  set t to contents of trackRef
  if trackJSON is not "" then set trackJSON to trackJSON & ","
  set trackJSON to trackJSON & "["
  set fieldJSON to my quoteJSON((persistent ID of t) as text)
  set trackJSON to trackJSON & fieldJSON & ","
  set fieldJSON to my quoteJSON(name of t)
  set trackJSON to trackJSON & fieldJSON & ","
  set fieldJSON to my quoteJSON(album of t)
  set trackJSON to trackJSON & fieldJSON & ","
  set fieldJSON to my quoteJSON(album artist of t)
  set trackJSON to trackJSON & fieldJSON & ","
  set fieldJSON to my quoteJSON(artist of t)
  set trackJSON to trackJSON & fieldJSON & ","
  set trackJSON to trackJSON & (track number of t as text) & ","
  set trackJSON to trackJSON & (disc number of t as text) & ","
  set trackJSON to trackJSON & (year of t as text) & ","
  set fieldJSON to my boolJSON(compilation of t)
  set trackJSON to trackJSON & fieldJSON & ","
  set fieldJSON to my quoteJSON(grouping of t)
  set trackJSON to trackJSON & fieldJSON & "]"
 end repeat
 end tell
 set playlistJSON to ""
 tell application "Music"
  repeat with p in every user playlist
   set pn to name of p
   set sk to special kind of p as text
   if sk is "none" and not (pn begins with "Crate " and pn contains "Now Playing") then
    set pid to persistent ID of p as text
    set firstID to ""
    try
     set firstID to persistent ID of first track of p as text
    end try
    if playlistJSON is not "" then set playlistJSON to playlistJSON & ","
    set playlistJSON to playlistJSON & "[" & my quoteJSON(pn) & "," & my quoteJSON(pid) & "," & my quoteJSON(firstID) & "]"
   end if
  end repeat
 end tell
 return "{\"tracks\":[" & trackJSON & "],\"pls\":[" & playlistJSON & "]}"
end run
on quoteJSON(valueText)
 set valueText to valueText as text
 set valueText to my replaceText(valueText, "\\", "\\\\")
 set valueText to my replaceText(valueText, "\"", "\\\"")
 set valueText to my replaceText(valueText, (ASCII character 13), "\\r")
 set valueText to my replaceText(valueText, (ASCII character 10), "\\n")
 return "\"" & valueText & "\""
end quoteJSON
on boolJSON(valueBoolean)
 if valueBoolean then return "true"
 return "false"
end boolJSON
on replaceText(sourceText, searchText, replacementText)
 set oldDelimiters to AppleScript's text item delimiters
 set AppleScript's text item delimiters to searchText
 set textItems to text items of sourceText
 set AppleScript's text item delimiters to replacementText
 set outputText to textItems as text
 set AppleScript's text item delimiters to oldDelimiters
 return outputText
end replaceText
AS
my $START=<<'AS';
on run argv
 set playMode to item 1 of argv
 set playlistName to item 2 of argv
 try
  tell application "Music"
   if playMode is "pl" then
    set p to first user playlist whose persistent ID is playlistName
   else if playMode is "al" then
    set shuffle enabled to false
    set cratePlaylists to every user playlist whose name begins with "Crate "
    set p to missing value
    repeat with candidate in cratePlaylists
     set candidateName to name of candidate as text
     if candidateName contains "Now Playing" then
      set p to contents of candidate
      exit repeat
     end if
    end repeat
    if p is missing value then
     set p to make new user playlist with properties {name:playlistName}
    else
     if name of p is not playlistName then set name of p to playlistName
     delete every track of p
    end if
    repeat with i from 3 to count of argv
     set pid to item i of argv
     set t to first track of library playlist 1 whose persistent ID is pid
     duplicate t to p
    end repeat
   else
    error "Invalid playback request"
   end if
   if (count of tracks of p) is 0 then error "Playlist is empty"
   play p
  end tell
  return "ok"
 on error e number n
  return "ERROR: " & e & " (" & n & ")"
 end try
end run
AS
my $ART=<<'AS';
on run argv
 set pid to item 1 of argv
 set out to item 2 of argv
 try
  tell application "Music"
   set t to first track of library playlist 1 whose persistent ID is pid
   set d to raw data of artwork 1 of t
  end tell
  set f to open for access POSIX file out with write permission
  set eof f to 0
  write d to f
  close access f
 end try
end run
AS
sub handle{my($c,$m,$path,$q,$body)=@_;
 if($path eq '/api/library'){my $f="$cache/library-v2.json"; my $d=($q!~/refresh/)?slurp($f):undef;
   if(!$d){$d=osa('AppleScript',$LIB); if($d!~/^\{/){$d=encode_json({error=>"Could not read Apple Music through Crate's automation permission: ".substr($d,0,300)})} else{spit($f,$d)}}
   resp($c,'200 OK','application/json',$d)}
 elsif($path eq '/api/art'){my($pid)=$q=~/pid=([0-9A-Fa-f]+)/; return resp($c,'400 Bad','text/plain','x') unless $pid;
   my $f="$cache/art/$pid.img"; osa('AppleScript',$ART,$pid,$f) unless -s $f; my $d=slurp($f);
   return resp($c,'404 NF','text/plain','none') unless $d && length $d>100;
   resp($c,'200 OK',$d=~/^\x89PNG/?'image/png':'image/jpeg',$d)}
  elsif($path eq '/api/play'){
    my $request=eval{decode_json($body)};
    if($@ || ref($request) ne 'HASH'){resp($c,'400 Bad Request','application/json',encode_json({error=>'Invalid playback request'}))}
     elsif(($request->{kind}//'') eq 'pl' && ($request->{id}//'')=~/\A[0-9A-Fa-f]+\z/){
       my $started=osa('AppleScript',$START,'pl',$request->{id});
        if($started!~/\Aok\s*\z/){resp($c,'500 Internal Server Error','application/json',encode_json({error=>$started=~/^ERROR:/?$started:"Apple Music did not confirm playback. Check Crate's Music automation permission in System Settings > Privacy & Security > Automation."}))}
       else{resp($c,'200 OK','application/json',encode_json({ok=>1}))}
     }
      elsif(($request->{kind}//'') eq 'al' && ref($request->{albums}) eq 'ARRAY'){
       my @ids;
       my $valid=1;
       for my $album (@{$request->{albums}}){
         if(ref($album) ne 'HASH' || ref($album->{ids}) ne 'ARRAY' || !@{$album->{ids}}){$valid=0;last}
         for my $id (@{$album->{ids}}){if(!defined($id) || $id!~/\A[0-9A-Fa-f]+\z/){$valid=0;last} push @ids,$id}
         last unless $valid;
       }
       if(!$valid || !@ids){resp($c,'400 Bad Request','application/json',encode_json({error=>'Invalid album playback request'}))}
       else{my $target='Crate - Now Playing';
         my $started=osa('AppleScript',$START,'al',$target,@ids);
         if($started!~/\Aok\s*\z/){resp($c,'500 Internal Server Error','application/json',encode_json({error=>$started=~/^ERROR:/?$started:"Apple Music did not confirm playback. Check Crate's Music automation permission in System Settings > Privacy & Security > Automation."}))}
         else{resp($c,'200 OK','application/json',encode_json({ok=>1}))}}
     }
     else{resp($c,'400 Bad Request','application/json',encode_json({error=>'Invalid playback request'}))}
   }
 elsif($path eq '/api/cmd'){my($k)=$q=~/c=(\w+)/; my %m=(playpause=>'playpause',next=>'next track',prev=>'previous track');
   osa('AppleScript',"tell application \"Music\" to $m{$k}") if $m{$k||''}; resp($c,'200 OK','text/plain','ok')}
 elsif($path eq '/api/now'){my $o=osa('AppleScript','if application "Music" is running then tell application "Music" to if player state is not stopped then return (player state as text) & "|" & (name of current track) & "|" & (artist of current track) & "|" & (album of current track) & "|" & (album artist of current track)');
   chomp $o; resp($c,'200 OK','text/plain; charset=utf-8',$o)}}
while(1){my @r=$sel->can_read(5); if(!@r){exit 0 if $seen && time-$last>45; next}
 my $c=$srv->accept or next; $c->autoflush(1); $c->timeout(5);
 my $line=<$c>; next unless $line; my($m,$u)=$line=~/^(\w+) (\S+)/ or next; my $len=0;
 while(my $h=<$c>){last if $h=~/^\r?\n$/; $len=$1 if $h=~/^Content-Length:\s*(\d+)/i}
 my $body=''; while(length($body)<$len){my $chunk='';my $n=read($c,$chunk,$len-length($body));last unless $n;$body.=$chunk}
 my($path,$q)=split /\?/,$u,2; $q//='';
 if($path eq '/ping'){$last=time;$seen=1;$ui=1 if $q=~/ui=1/;resp($c,'200 OK','text/plain','ok')}
 elsif($path eq '/loaded'){$ui=0 if $q=~/reset/;resp($c,'200 OK','text/plain',$ui?'yes':'no')}
 elsif($path eq '/'){my $page=slurp("$res/index.html"); if(defined $page){resp($c,'200 OK','text/html; charset=utf-8',$page)}else{resp($c,'500 Internal Server Error','text/plain; charset=utf-8','Crate could not read its interface files. Quit and reopen the app.')}} 
 elsif($path eq '/api/flags'){ if($m eq 'POST'){spit("$sup/flags.json",$body);resp($c,'200 OK','application/json','{}')} else{resp($c,'200 OK','application/json',slurp("$sup/flags.json")||'{}')}}
 else{my $pid=fork; if(defined $pid && !$pid){handle($c,$m,$path,$q,$body);exit 0} }
 close $c}
