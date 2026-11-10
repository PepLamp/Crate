use strict; use warnings; use IO::Socket::INET; use IO::Select; use JSON::PP; use File::Path 'make_path';
use Digest::SHA qw(sha256); use MIME::Base64 qw(encode_base64); use URI::Escape qw(uri_escape_utf8 uri_unescape); use HTTP::Tiny;
my($port,$res)=@ARGV; my $home=$ENV{HOME};
my $cache="$home/Library/Caches/Crate"; my $sup="$home/Library/Application Support/Crate";
make_path("$cache/art",$sup); $SIG{CHLD}='IGNORE'; $SIG{PIPE}='IGNORE';
my $spotify_settings="$sup/spotify-settings.json"; my $spotify_auth="$sup/spotify-auth.json"; my $spotify_pending="$sup/spotify-pending.json";
my $spotify_redirect="http://127.0.0.1:$port/spotify/callback";
my $srv=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>$port,Listen=>30,ReuseAddr=>1,Proto=>'tcp') or die "port";
my $sel=IO::Select->new($srv); my($last,$seen,$ui)=(time,0,0);
sub slurp{my $f=shift; open(my $h,'<:raw',$f) or return undef; local $/; my $d=<$h>; close $h; $d}
sub spit{my($f,$d)=@_; utf8::encode($d) if utf8::is_utf8($d); open(my $h,'>:raw',$f) or return; print $h $d; close $h}
sub secure_spit{my($f,$d)=@_; my $old=umask 0077; my $ok=spit($f,$d); umask $old; return 0 unless $ok; return chmod 0600,$f}
sub remove_optional{my($f)=@_; return 1 unless -e $f; return unlink $f}
sub read_json{my($f)=@_; my $d=slurp($f); return undef unless defined $d; my $v=eval{decode_json($d)}; return $@?undef:$v}
sub spotify_client_id{my $s=read_json($spotify_settings); return ref($s) eq 'HASH'?$s->{client_id}:undef}
sub spotify_http{HTTP::Tiny->new(timeout=>30,verify_SSL=>1,agent=>'Crate Spotify Library/1.0')}
sub spotify_api_error{my($response)=@_; my $data=eval{decode_json($response->{content}//'')}; my $message=ref($data) eq 'HASH' && ref($data->{error}) eq 'HASH'?$data->{error}{message}:undef; $message||="Spotify returned HTTP $response->{status}"; $message.=" (retry after $response->{headers}{'retry-after'} seconds)" if $response->{status}==429 && $response->{headers}{'retry-after'}; return $message}
sub spotify_access_token{
 my $auth=read_json($spotify_auth); return(undef,'Spotify is not connected') unless ref($auth) eq 'HASH' && $auth->{refresh_token};
 return($auth->{access_token},undef) if $auth->{access_token} && ($auth->{expires_at}//0)>time+60;
 my $client_id=spotify_client_id(); return(undef,'Save your Spotify Client ID first') unless $client_id;
 my $response=spotify_http()->post_form('https://accounts.spotify.com/api/token',{grant_type=>'refresh_token',refresh_token=>$auth->{refresh_token},client_id=>$client_id});
 return(undef,'Could not refresh Spotify authorization: '.spotify_api_error($response)) unless $response->{success};
 my $token=eval{decode_json($response->{content})}; return(undef,'Spotify returned an invalid token response') unless ref($token) eq 'HASH' && $token->{access_token};
 $auth->{access_token}=$token->{access_token}; $auth->{expires_at}=time+($token->{expires_in}//3600); $auth->{refresh_token}=$token->{refresh_token} if $token->{refresh_token};
 return(undef,'Could not securely save Spotify authorization') unless secure_spit($spotify_auth,encode_json($auth));
 return($auth->{access_token},undef)
}
sub spotify_all_pages{
 my($start,$token)=@_; my @items; my %seen; my $url=$start;
 while(defined $url && length $url){
  return(undef,'Spotify pagination returned an invalid URL') unless $url=~m{\Ahttps://api\.spotify\.com/v1/me/(?:albums|playlists)(?:\?.*)?\z};
  return(undef,'Spotify pagination repeated a page') if $seen{$url}++;
  my $response=spotify_http()->get($url,{headers=>{Authorization=>"Bearer $token"}});
  return(undef,spotify_api_error($response)) unless $response->{success};
  my $page=eval{decode_json($response->{content})}; return(undef,'Spotify returned invalid library data') unless ref($page) eq 'HASH' && ref($page->{items}) eq 'ARRAY';
  push @items,@{$page->{items}}; return(undef,'Spotify library is too large to load safely') if @items>20000;
  $url=$page->{next}
 }
 return(\@items,undef)
}
sub spotify_library{
 my($token)=@_; my($saved,$error)=spotify_all_pages('https://api.spotify.com/v1/me/albums?limit=50',$token); return(undef,$error) unless $saved;
 my($playlists,$playlist_error)=spotify_all_pages('https://api.spotify.com/v1/me/playlists?limit=50',$token); return(undef,$playlist_error) unless $playlists;
 my(@albums,@playlist_records);
 for my $item(@$saved){
  my $a=ref($item) eq 'HASH'?$item->{album}:undef; next unless ref($a) eq 'HASH' && $a->{id};
  push @albums,{key=>"spotify:album:$a->{id}",source=>'spotify',kind=>'album',title=>$a->{name}//'Unknown Album',artist=>(ref($a->{artists}) eq 'ARRAY' && @{$a->{artists}}?($a->{artists}[0]{name}//'Unknown Artist'):'Unknown Artist'),art=>(ref($a->{images}) eq 'ARRAY' && @{$a->{images}}?$a->{images}[0]{url}:''),spotifyUrl=>((ref($a->{external_urls}) eq 'HASH'?$a->{external_urls}{spotify}:undef)||"https://open.spotify.com/album/$a->{id}")}
 }
 for my $p(@$playlists){
  next unless ref($p) eq 'HASH' && $p->{id};
  push @playlist_records,{key=>"spotify:playlist:$p->{id}",source=>'spotify',kind=>'playlist',title=>$p->{name}//'Unknown Playlist',artist=>(ref($p->{owner}) eq 'HASH'?($p->{owner}{display_name}//'Playlist'):'Playlist'),art=>(ref($p->{images}) eq 'ARRAY' && @{$p->{images}}?$p->{images}[0]{url}:''),spotifyUrl=>((ref($p->{external_urls}) eq 'HASH'?$p->{external_urls}{spotify}:undef)||"https://open.spotify.com/playlist/$p->{id}")}
 }
 return({albums=>\@albums,playlists=>\@playlist_records},undef)
}
sub query_params{my($q)=@_; my %p; for my $part(split /&/,$q){my($k,$v)=split /=/,$part,2;$p{uri_unescape($k//'')}=uri_unescape($v//'')} return\%p}
sub random_b64url{my($bytes)=@_; open(my $f,'<:raw','/dev/urandom') or die 'Secure random source unavailable'; my $data=''; my $n=read($f,$data,$bytes); close $f; die 'Could not read secure random data' unless defined($n) && $n==$bytes; my $encoded=encode_base64($data,''); $encoded=~tr!+/!-_!; $encoded=~s/=+\z//; return $encoded}
sub spotify_callback_page{my($message)=@_; $message=~s/&/&amp;/g; $message=~s/</&lt;/g; $message=~s/>/&gt;/g; return '<!doctype html><meta charset="utf-8"><title>Crate Spotify</title><p>'.$message.'</p><p>You can close this tab and return to Crate.</p>'}
sub resp{my($c,$code,$type,$body)=@_; my $cc=$type=~/^image/?'max-age=86400':'no-store';
  utf8::encode($body) if utf8::is_utf8($body);
  print $c "HTTP/1.1 $code\r\nContent-Type: $type\r\nContent-Length: ".length($body)."\r\nCache-Control: $cc\r\nConnection: close\r\n\r\n$body"}
sub redirect_resp{my($c,$url)=@_; print $c "HTTP/1.1 302 Found\r\nLocation: $url\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"}
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
 if($path eq '/api/spotify/settings'){
  if($m eq 'POST'){
   my $request=eval{decode_json($body)};
   if($@ || ref($request) ne 'HASH' || !defined($request->{client_id}) || $request->{client_id}!~/\A[A-Za-z0-9]{10,128}\z/){resp($c,'400 Bad Request','application/json',encode_json({error=>'Enter a valid Spotify Client ID'}))}
   else{my $previous=spotify_client_id();
    if(defined($previous) && $previous ne $request->{client_id} && (!remove_optional($spotify_auth) || !remove_optional($spotify_pending))){resp($c,'500 Internal Server Error','application/json',encode_json({error=>'Could not remove the previous Spotify authorization'}))}
    elsif(!secure_spit($spotify_settings,encode_json({client_id=>$request->{client_id}}))){resp($c,'500 Internal Server Error','application/json',encode_json({error=>'Could not save Spotify settings securely'}))}
    else{resp($c,'200 OK','application/json',encode_json({client_id=>$request->{client_id}}))}
   }
  }else{resp($c,'200 OK','application/json',encode_json({client_id=>spotify_client_id()//''}))}
 }
 elsif($path eq '/api/spotify/status'){
  my $auth=read_json($spotify_auth); my $pending=read_json($spotify_pending);
  if(ref($pending) eq 'HASH' && time-($pending->{created_at}//0)>600){unlink $spotify_pending;$pending=undef}
  resp($c,'200 OK','application/json',encode_json({configured=>spotify_client_id()?1:0,connected=>(ref($auth) eq 'HASH' && $auth->{refresh_token})?1:0,pending=>ref($pending) eq 'HASH'?1:0}))
 }
 elsif($path eq '/spotify/start'){
  my $client_id=spotify_client_id();
  if(!$client_id){resp($c,'400 Bad Request','text/plain; charset=utf-8','Save your Spotify Client ID in Crate first.')}
  else{my $state=eval{random_b64url(32)}; my $verifier=eval{random_b64url(64)};
   if($@){resp($c,'500 Internal Server Error','text/plain; charset=utf-8',"Could not start secure Spotify authorization: $@")}
   else{my $challenge=encode_base64(sha256($verifier),'');$challenge=~tr!+/!-_!;$challenge=~s/=+\z//;
    if(!secure_spit($spotify_pending,encode_json({state=>$state,verifier=>$verifier,client_id=>$client_id,created_at=>time}))){
     resp($c,'500 Internal Server Error','text/plain; charset=utf-8','Could not save Spotify authorization state securely.')
    }else{
    my $scope='user-library-read playlist-read-private playlist-read-collaborative';
    my @values=($client_id,'code',$spotify_redirect,'S256',$challenge,$state,$scope);
    my @pairs; for my $i(0..$#values){push @pairs,uri_escape_utf8(('client_id','response_type','redirect_uri','code_challenge_method','code_challenge','state','scope')[$i]).'='.uri_escape_utf8($values[$i])}
    my $url='https://accounts.spotify.com/authorize?'.join('&',@pairs);
    redirect_resp($c,$url)}
   }
  }
 }
 elsif($path eq '/spotify/callback'){
  my $params=query_params($q); my $pending=read_json($spotify_pending);
  if(ref($pending) ne 'HASH' || !defined($params->{state}) || $params->{state} ne ($pending->{state}//'')){resp($c,'400 Bad Request','text/html; charset=utf-8',spotify_callback_page('Spotify authorization could not be verified. Return to Crate and try again.'))}
  elsif(defined $params->{error}){unlink $spotify_pending;resp($c,'200 OK','text/html; charset=utf-8',spotify_callback_page('Spotify authorization was cancelled. Return to Crate and try again.'))}
  elsif(!defined($params->{code}) || time-($pending->{created_at}//0)>600){unlink $spotify_pending;resp($c,'400 Bad Request','text/html; charset=utf-8',spotify_callback_page('Spotify authorization expired. Return to Crate and try again.'))}
  else{unlink $spotify_pending;
   my $response=spotify_http()->post_form('https://accounts.spotify.com/api/token',{grant_type=>'authorization_code',code=>$params->{code},redirect_uri=>$spotify_redirect,client_id=>$pending->{client_id},code_verifier=>$pending->{verifier}});
   if(!$response->{success}){resp($c,'400 Bad Request','text/html; charset=utf-8',spotify_callback_page('Spotify connection failed: '.spotify_api_error($response)))}
   else{my $token=eval{decode_json($response->{content})};
    if(ref($token) ne 'HASH' || !$token->{access_token} || !$token->{refresh_token}){resp($c,'500 Internal Server Error','text/html; charset=utf-8',spotify_callback_page('Spotify returned an invalid token response.'))}
    else{$token->{expires_at}=time+($token->{expires_in}//3600);
     if(!secure_spit($spotify_auth,encode_json($token))){resp($c,'500 Internal Server Error','text/html; charset=utf-8',spotify_callback_page('Crate could not securely save the Spotify authorization.'))}
     else{resp($c,'200 OK','text/html; charset=utf-8',spotify_callback_page('Spotify is connected to Crate.'))}
    }
   }
  }
 }
 elsif($path eq '/api/spotify/disconnect'){
  if(!remove_optional($spotify_auth) || !remove_optional($spotify_pending) || !remove_optional("$cache/spotify-library.json")){resp($c,'500 Internal Server Error','application/json',encode_json({error=>'Could not remove all Spotify connection data'}))}
  else{resp($c,'200 OK','application/json',encode_json({ok=>1}))}
 }
 elsif($path eq '/api/spotify/library'){
  my($token,$error)=spotify_access_token();
  if($error){resp($c,'401 Unauthorized','application/json',encode_json({error=>$error}))}
  else{my($data,$library_error)=spotify_library($token); if($library_error){resp($c,'502 Bad Gateway','application/json',encode_json({error=>"Could not load Spotify library: $library_error"}))}
   else{resp($c,'200 OK','application/json',encode_json($data))}}
 }
 elsif($path eq '/api/library'){my $f="$cache/library-v2.json"; my $d=($q!~/refresh/)?slurp($f):undef;
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
