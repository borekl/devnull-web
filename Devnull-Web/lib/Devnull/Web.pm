#=============================================================================
# /DEV/NULL/NETHACK TOURNAMENT WEBSITE
# """"""""""""""""""""""""""""""""""""
# (c) 2017 Borek Lupomesky <borek@lupomesky.cz>
#
# Reimplementation if /dev/null/nethack website code to replace the original
# Krystal one. Please read the README for installation and deployment info.
#=============================================================================

package Devnull::Web;
use Dancer2;
use Dancer2::Plugin::Database;
use Dancer2::Plugin::Passphrase;
use Syntax::Keyword::Try;

our $VERSION = '0.1';


#=============================================================================
#====   __   ============   _   _  ===========================================
#===   / _|_   _ _ __   ___| |_(_) ___  _ __  ___   ==========================
#===  | |_| | | | '_ \ / __| __| |/ _ \| '_ \/ __|  ==========================
#===  |  _| |_| | | | | (__| |_| | (_) | | | \__ \  ==========================
#===  |_|  \__,_|_| |_|\___|\__|_|\___/|_| |_|___/  ==========================
#===                                               ===========================
#=============================================================================

sub plr_authenticate
{
  #--- arguments

  my (
    $name,     # 1. player name
    $pwd       # 2. password
  ) = @_;

  #--- authenticate

  if($name && $pwd) {
    my $sth = database->prepare('SELECT pwd FROM players WHERE name = ?');
    my $r = $sth->execute($name);
    if(!$r) { return "Failed to query database"; }
    my ($pw_db) = $sth->fetchrow_array();
    if($pw_db && passphrase($pwd)->matches($pw_db)) {
      return [];
    } else {
      return "Wrong player name or password";
    }
  }

  #--- invalid arguments

  return "Player name or password not specified";
}


sub plr_register
{
  #--- arguments

  my (
    my $name,
    my $pwd
  ) = @_;

  #--- perform registration

  my $r = database->do(
    'INSERT INTO players ( name, pwd ) VALUES ( ?, ? )',
    undef, $name, passphrase($pwd)->generate->rfc2307()
  );
  if(!$r) {
    my $err = database->errstr();
    if($err =~ /^UNIQUE constraint failed/) {
      return "Player name '$name' already exists, please choose different name";
    } else {
      return "Failed to create new player";
    }
  }

  return [];
}


#=============================================================================
# Returns hashref with player info in following keys:
#
#   clan_name, clan_admin, clan_id, players_i
#
# If extended info is requested, then additional keys are returned:
#
#   can_leave, sole_admin
#
# 'sole_admin' is true if the player is the only admin in the clan,
# 'can_leave' is true if the player can leave the clan; player can leave only
# when there is another clan admin OR he is the last remaining member.
#=============================================================================

sub plr_info
{
  #--- arguments

  my ($name, $extended) = @_;

  #--- other variables

  my $re;

  #--- get the info

  my $sth = database->prepare(
    'SELECT c.name AS clan_name, p.clan_admin AS clan_admin, '
    . 'p.clans_i AS clan_id, p.players_i '
    . 'FROM players p LEFT JOIN clans c '
    . 'USING ( clans_i ) WHERE p.name = ?'
  );
  if(!ref($sth)) { return "Failed to get database handle\n"; }
  my $r = $sth->execute($name);
  if(!$r) { return "Failed to query database\n"; }
  $r = $sth->fetchrow_hashref('NAME_lc');
  if(!$r) {
    return "Player not found";
  }
  $re = $r;

  #--- get extended information

  if($extended) {

    my $clan = $re->{'clan_name'};
    my $clan_info = clan_get_info($clan);
    if(!ref($clan_info)) {
      return sprintf(
        "Failed to get clan info for clan %s (%s)",
        $clan, $clan_info
      );
    }

    my $clan_members_count = keys %{$clan_info->{$clan}};
    my $clan_admins_count = grep {
      $clan_info->{$clan}{$_}{clan_admin}
    } keys %{$clan_info->{$clan}};

    $re->{'sole_admin'} = ($clan_admins_count == 1) + 0;
    if(
      $clan_admins_count > 1
      || $clan_admins_count == $clan_members_count
    ) {
      $re->{'can_leave'} = 1;
    } else {
      $re->{'can_leave'} = 0;
    }
  }

  #--- finish

  return $re;
}


sub plr_start_clan
{
  #--- arguments

  my ($player_name, $clan_name) = @_;

  #--- ensure player is not clan member already

  my $plr = plr_info($player_name);
  if(!ref($plr)) { return "Failed to get player info ($plr)"; }
  if($plr->{'clan_name'}) {
    return "Player '$player_name' is already a clan member";
  }

  #--- start transaction

  my $r = database->begin_work();
  if(!$r) { return 'Failed to start database transaction'; }

  my $clans_i;
  try {

  #--- create new clan

    $r = database->do(
      'INSERT INTO clans ( name ) VALUES ( ? )',
      undef, $clan_name
    );
    if(!$r) {
      if(database->errstr() =~ /^UNIQUE constraint failed/) {
        die "The clan '$clan_name' already exists, please choose different name\n";
      } else {
        die sprintf("Failed to create a new clan (%s)\n", database->errstr());
      }
    }

  #--- get the clan's id

    my $sth = database->prepare(
      'SELECT clans_i FROM clans WHERE name = ?'
    );
    if(!ref($sth)) { die "Failed to get db query handle\n"; }
    $r = $sth->execute($clan_name);
    if(!$r) { die "Failed to query database\n"; }
    ($clans_i) = $sth->fetchrow_array();
    if(!$clans_i) { die "Failed to get new clan id\n"; }

  #--- make the player member and admin

    $r = database->do(
      'UPDATE players SET clan_admin = 1, clans_i = ? WHERE name = ?',
      undef, $clans_i, $player_name
    );
    if(!$r) { die "Failed to make user $player_name a clan admin\n"; }

  }

  #--- handle failure

  catch {
    chomp($@);
    database->rollback;
    return $@;
  }

  #--- commit transaction

  database->commit();
  return { clan_id => $clans_i };
}


sub plr_leave_clan
{
  #--- arguments

  my ($name) = @_;

  #--- start transaction

  my $r = database->begin_work();
  if(!$r) { return "Failed to start transaction"; }

  try {

  #--- get clan id

    my $plr = plr_info($name);
    die "Failed to get clan id for player '$name' ($plr)\n" if !ref($plr);
    my $clan_id = $plr->{'clan_id'};
    if(!$clan_id) { die "User not member of any clan already\n"; }

  #--- leave clan

    $r = database->do(
      'UPDATE players SET clans_i = NULL, clan_admin = 0 WHERE name = ?',
      undef, $name
    );
    if($r != 1) { die "Failed to leave clan\n"; }

  #--- drop all your invitations

    $r = database->do(
      'DELETE FROM invites WHERE invitor = ?', undef, $plr->{'players_i'}
    );
    if(!$r) {
      die sprintf("Failed to delete invitations (%s)\n", $r);
    }

  #--- delete the clan if no more users remain

    my $sth = database->prepare(
      'SELECT count(*) FROM players WHERE clans_i = ?'
    );
    $r = $sth->execute($clan_id);
    die "Failed to query database\n" if !$r;
    my ($remaining_cnt) = $sth->fetchrow_array();
    if($remaining_cnt == 0) {
      $r = database->do(
        'DELETE FROM clans WHERE clans_i = ?',
        undef, $clan_id
      );
      die "Failed to remove empty clan\n" if !$r;
    }

  } catch {
    chomp($@);
    database->rollback();
    return "Could not leave the clan ($@)";
  }

  #--- commit transaction

  database->commit();
  return [];
}


#=============================================================================
# Return players based on partial match anchored at start and optionally
# excluding players from specified clan.
#=============================================================================

sub plr_search
{
  #--- arguments

  my (
    $search,            # search string
    $exclude_clan_id    # exclude players with clan_id
  ) = @_;

  #--- query database

  my @args = ( "$search%" );
  my $qry =
    'SELECT p.name AS name, c.name AS clan, players_i, clans_i, clan_admin '
    . 'FROM players p LEFT JOIN clans c USING (clans_i)'
    . q{ WHERE p.name LIKE ?};
  if($exclude_clan_id) {
    $qry .= ' AND ( p.clans_i <> ? OR p.clans_i IS NULL )';
    push(@args, $exclude_clan_id);
  }
  my $sth = database->prepare($qry);
  if(!ref($sth)) { return "Failed to get database handle"; }
  my $r = $sth->execute(@args);
  if(!$r) {
    return sprintf "Failed to query database (%s)", $sth->errstr();
  }
  my $result = $sth->fetchall_hashref('name');
  return $result;
}


#=============================================================================
# Invite a player to a clan.
#=============================================================================

sub plr_invite
{
  #--- arguments

  my (
    $name,        # player doing the inviting
    $invitee      # player being invited
  ) = @_;

  #--- get information about players

  my $plr_invitor = plr_info($name);
  if(!ref($plr_invitor)) { return $plr_invitor; }
  my $plr_invitee = plr_info($invitee);
  if(!ref($plr_invitee)) { return $plr_invitee; }


  if(!$plr_invitor->{'clan_admin'}) {
    return "Only clan admins can invite players";
  }
  if($plr_invitor->{'clan_id'} == $plr_invitee->{'clan_id'}) {
    return "The invited player already is member of the clan";
  };

  #--- redundant invitation

  my $sth = database->prepare(
    'SELECT count(*) FROM invites WHERE invitor = ? AND invitee = ?'
  );
  if(!ref($sth)) { return "Failed to get database handle"; }
  my $r = $sth->execute(
    $plr_invitor->{'players_i'}, $plr_invitee->{'players_i'}
  );
  if(!$r) { return "Failed to query database"; }
  my ($cnt) = $sth->fetchrow_array();
  if($cnt == 1) { return "The player already has invitation waiting"; }

  #--- create new invitation

  $r = database->do(
    'INSERT INTO invites ( invitor, invitee ) VALUES ( ?, ? )', undef,
    $plr_invitor->{'players_i'}, $plr_invitee->{'players_i'}
  );
  if(!$r) { return "Failed to create an invitation"; }

  return [];
}


#=============================================================================
# For player supplied as the argument, return two lists references from
# hashref with two keys.  The 'invites' key references list of pending
# invites for the player as [ <invitor>, <clan> ]; the 'invitees' key
# references list of invitation the player has issued as [ <invitee> ].
#=============================================================================

sub plr_get_invitations
{
  #--- arguments

  my ($name) = @_;

  #--- get player info

  my $plr = plr_info($name);
  if(!ref($plr)) { return "Could not get player info ($plr)"; }

  #--- list of invites the player has issued

  my @my_invitees;
  my $sth = database->prepare(
    'SELECT name '
    . 'FROM invites LEFT JOIN players ON players_i = invitee '
    . 'WHERE invitor = ?'
  );
  if(!ref($sth)) { return "Failed to get database handle"; }
  my $r = $sth->execute($plr->{'players_i'});
  while(my ($invitee) = $sth->fetchrow_array()) {
    push(@my_invitees, $invitee);
  }

  #--- list of invites waiting for the player

  my @my_invites;
  $sth = database->prepare(
    'SELECT p.name AS player, c.name AS clan '
    . 'FROM invites i LEFT JOIN players p ON players_i = invitor '
    . 'LEFT JOIN clans c USING ( clans_i ) '
    . 'WHERE invitee = ?'
  );
  if(!ref($sth)) { return "Failed to get database handle"; }
  $r = $sth->execute($plr->{'players_i'});
  while(my @invite = $sth->fetchrow_array()) {
    push(@my_invites, \@invite);
  }

  return { invites => \@my_invites, invitees => \@my_invitees };
}


#=============================================================================
# Revoke (= remove) invitation(s) player has given to another player. If the
# invitee player is not specified, all invitations by the player are revoked.
# On error, error message is returned; on success hashref is returned with
# key 'deleted' which gives number of entries that were actually deleted.
#=============================================================================

sub plr_revoke_invitations
{
  #--- arguments

  my ($name, $invitee) = @_;

  #--- get info on both players

  my $plr_info = plr_info($name);
  if(!ref($plr_info)) { return $plr_info; }
  my $invitee_info;
  if($invitee) {
    $invitee_info = plr_info($invitee);
    if(!ref($invitee_info)) { return $invitee_info; }
  }

  #--- delete the invites

  my @args = $plr_info->{'players_i'};
  my $qry = 'DELETE FROM invites WHERE invitor = ?';
  if($invitee) {
    $qry .= ' AND invitee = ?';
    push(@args, $invitee_info->{'players_i'});
  }
  my $r = database->do($qry, undef, @args);
  if(!$r) {
    return
      sprintf "Failed to delete the invitation() (%s)", database->errstr();
  }

  #--- finish successfully

  return { deleted => $r };
}


#=============================================================================
# Function declines invitation the player has pending from another. Only the
# matching invitation is removed. Invitations from the other players for the
# same clan will not be deleted. If invitor is omitted, all pending
# invitations are declined.
#=============================================================================

sub plr_decline_invitation
{
  #--- arguments

  my ($name, $invitor) = @_;

  #--- get info on both players

  my $plr_info = plr_info($name);
  if(!ref($plr_info)) { return $plr_info; }
  my $invitor_info;
  if($invitor) {
    $invitor_info = plr_info($invitor);
    if(!ref($invitor_info)) { return $invitor_info; }
  }

  #--- delete the invite

  my @args = ( $plr_info->{'players_i'} );
  my $qry = 'DELETE FROM invites WHERE invitee = ?';
  if($invitor) {
    $qry .= ' AND invitor = ?';
    push(@args, $invitor_info->{'players_i'});
  }
  my $r = database->do($qry, undef, @args);
  if(!$r) {
    return
      sprintf "Failed to delete the invitation(s) (%s)", database->errstr();
  }

  #--- finish successfully

  return { deleted => $r };
}


#=============================================================================
# Function that accepts pending invitation from an invitor. This function
# also drops all pending invitiation for the same clan as the invitor's clan.
#=============================================================================

sub plr_accept_invitation
{
  #--- arguments

  my ($name, $invitor) = @_;

  #--- get info on both players

  my $plr_info = plr_info($name);
  if(!ref($plr_info)) { return $plr_info; }
  my $invitor_info;
  if($invitor) {
    $invitor_info = plr_info($invitor);
    if(!ref($invitor_info)) { return $invitor_info; }
  }

  #--- get invitations list

  my $invitations = plr_get_invitations($name);

  #--- begin transaction

  my $r = database->begin_work();
  if(!$r) { return "Could not start database transaction"; }

  try {

  #--- update player record to include clan id

    my $r = database->do(
      'UPDATE players SET clans_i = ? WHERE players_i = ?', undef,
      $invitor_info->{'clan_id'}, $plr_info->{'players_i'}
    );
    if(!$r) { die "Failed to update database ($r)\n"; }

  #--- find all invitations for the same clan

    my $sth = database->prepare(
      'SELECT invitor, invitee ' .
      'FROM invites ' .
      'LEFT JOIN players ON invitor = players_i ' .
      'LEFT JOIN clans USING (clans_i) ' .
      'WHERE invitee = ? AND clans_i = ?'
    );
    if(!ref($sth)) {
      die sprintf("Failed to get query handle (%s)\n", database->errstr());
    }
    $r = $sth->execute($plr_info->{'players_i'},$invitor_info->{'clan_id'});
    if(!$r) { die sprint("Failed to query database (%s)\n", $sth->errstr()); }
    my $invites = $sth->fetchall_arrayref();
    if(!$invites) {
      die sprintf "Failed to retrieve database query (%s)\n", $sth->errstr();
    }

  #--- delete all invitations matched in previous step

    for my $row (@$invites) {
      $r = database->do(
        'DELETE FROM invites WHERE invitor = ? AND invitee = ?', undef,
        @$row
      );
      if(!$r) {
        die sprintf("Failed to delete invitation (%s)\n", database->errstr());
      }
    }

  #--- abort transaction on error

  } catch {
    chomp($@);
    database->rollback();
    return "Could not accept clan invitation ($@)";
  }

  #--- commit transaction

  database->commit();
  return [];
}


#=============================================================================
# Get clan info listing for specified clan or all clans.
#=============================================================================

sub clan_get_info
{
  #--- arguments

  my ($clan) = @_;

  #--- query the database

  my $sth = database->prepare(
    'SELECT c.name AS clan, clans_i, p.name AS player, players_i, clan_admin ' .
    'FROM clans c LEFT JOIN players p USING (clans_i)' .
    ($clan ? ' WHERE c.name = ?' : '')
  );
  if(!ref($sth)) { return "Couldn't get query handle\n"; }
  my $r = $sth->execute($clan ? ($clan) : ());
  if(!$r) {
    die sprintf("Failed to query database (%s)\n", $r);
  }

  my %re;
  while(my $row = $sth->fetchrow_hashref()) {
    $re
      {$row->{'clan'}}
      {$row->{'player'}}
    = $row;
  }

  return \%re;

}


#=============================================================================
#==================   _  =====================================================
#===  _ __ ___  _   _| |_ ___  ___   =========================================
#=== | '__/ _ \| | | | __/ _ \/ __|  =========================================
#=== | | | (_) | |_| | ||  __/\__ \  =========================================
#=== |_|  \___/ \__,_|\__\___||___/  =========================================
#===                                ==========================================
#=============================================================================

# following URLs are implemented:
#
# GET  /                  ... front page
# GET  /logout            ... log out
# GET  /login             ... display log in page
# POST /login             ... log in
# GET  /register          ... display new player registration page
# POST /register          ... perform new player registration
# GET  /player            ... player personal administration page
# GET  /leave_clan        ... leave current clan
# any  /start_clan        ... starts new clan with the player as admin
# any  /invite            ... display player invitation page
# GET  /invite/<invitee>  ... invite a player to a clan
# GET  /revoke/<invitee>  ... revoke an existing invitation
# GET  /revoke            ... revoke all issued invitations
# GET  /decline/<invitor> ... decline a pending invitation
# GET  /decline           ... decline all pending invitations
# GET  /accept/<invitor>  ... accept a pending invitation
# GET  /make_admin        ... display make admin page
# GET  /make_admin/<plr>  ... give admin rights to another clan member
# GET  /resign_admin      ... resign admin rights
# GET  /clan/<clan>       ... clan info page


#=============================================================================
#=== front page ==============================================================
#=============================================================================

get '/' => sub {
  my $data = { title => 'Devnull Front Page' };
  my $logname = session('logname');
  if($logname) { $data->{'logname'} = $logname; }
  template 'index', $data;
};

#=============================================================================
#=== logout ==================================================================
#=============================================================================

get '/logout' => sub {
  app->destroy_session();
  redirect '/';
};

#=============================================================================
#=== login ===================================================================
#=============================================================================

get '/login' => sub {
  template 'login', {
    title => 'Devnull Log in'
  };
};

post '/login' => sub {
  my $name = body_parameters->get('reg_name');
  my $pw_web = body_parameters->get('reg_pwd1');

  my $r = plr_authenticate($name, $pw_web);
  if(ref($r)) {
    session logname => $name;
    redirect '/';
  }

  template 'login', {
    title => 'Devnull Log in',
    errmsg => "Cannot login: $r"
  };
};

#=============================================================================
#=== player registration =====================================================
#=============================================================================

get '/register' => sub {
  template 'register', {
    title => 'Devnull New User Registration'
  };
};

post '/register' => sub {
  my $response = { title => 'Devnull New User Registration' };

  try {
    my $name = body_parameters->get('reg_name');
    my $pw1 = body_parameters->get('reg_pwd1');
    my $pw2 = body_parameters->get('reg_pwd2');

    #--- one or more inputs not filled in

    if(!$name || !$pw1 || !$pw2) {
      die "Please fill in all three fields\n";
    }

    #--- non-matching passwords

    if($pw1 ne $pw2) {
      die "The passwords do not match\n";
    }

    #--- password is too short

    if(length($pw1) < 6) {
      die "Please use longer password (at least 6 characters)\n";
    }

    #--- create new player

    my $r = plr_register($name, $pw1);
    if(ref($r)) {
      session logname => $name;
      redirect '/';
    } else {
      die "Failed to create new player\n";
    }

  } catch {
    chomp($response->{'errmsg'} = $@);
  }

  return template 'register', $response;
};

#=============================================================================
#=== player admin page =======================================================
#=============================================================================

get '/player' => sub {

  #--- this is only for authenticated users, boot anyone who is not logged in

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- get player information

  my $plr = plr_info($name, 1);
  if(!ref($plr)) {
    return $plr;
  }

  #--- get invitation info for the user

  my $invinfo = plr_get_invitations($name);

  #--- serve the page

  template 'player', {
    title => "Devnull Player $name",
    clan => $plr->{'clan_name'},
    admin => $plr->{'clan_admin'},
    sole_admin => $plr->{'sole_admin'},
    can_leave => $plr->{'can_leave'},
    invinfo => $invinfo,
    logname => $name
  };
};


#=============================================================================
#=== player clan leave =======================================================
#=============================================================================

get '/leave_clan' => sub {

  #--- this is only for authenticated users, boot anyone who is not logged in

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- leave clan

  my $r = plr_leave_clan($name);
  if(!ref($r)) { return $r; }
  redirect '/player';
};


#=============================================================================
#=== player clan create ======================================================
#=============================================================================

any '/create_clan' => sub {

  my $data = {
    title => 'Devnull / Start a new clan'
  };

  #--- this is only for authenticated users, boot anyone who is not logged in

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- if this is POST request, process the submitted data

  if(request->is_post) {

  #--- get clan name, make sure it is sensible (FIXME: more checks needed)

    my $clan_name = body_parameters->get('clan_name');
    if(!$clan_name) {
      $data->{'errmsg'} = 'Please fill in clan name'
    }

  #--- create a new clan

    else {
      my $r = plr_start_clan($name, $clan_name);
      if(!ref($r)) {
        $data->{'errmsg'} = "Failed to start a clan: $r";
      }
    }

  }

  #--- finish

  if($data->{'errmsg'} || request->is_get) {
    return template 'clan_create', $data;
  } else {
    redirect '/player';
  }

};


#=============================================================================
#=== invite ==================================================================
#=============================================================================

any '/invite' => sub {

  my $data = {
    title => 'Devnull / Invite a player'
  };

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- only for clan admins

  my $plr = plr_info($name);
  if(!ref($plr)) { return "Failed to get player info"; }
  if(!$plr->{'clan_admin'}) { return "Only clan admins can invite players"; }

  #--- process POST data

  if(request->is_post) {
    my $invite_search = body_parameters->get('invite_name');
    my $plrlist = plr_search($invite_search, $plr->{'clan_id'});
    if(!ref($plrlist)) {
      return "Couldn't get list of players ($plrlist)";
    }
    $data->{'plrlist'} = [ sort keys %$plrlist ];
  }

  #--- serve a form

  template 'invite', $data;

};

get '/invite/:invitee' => sub {

  my $data = {
    title => 'Devnull / Invite a player'
  };

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- only for clan admins

  my $plr = plr_info($name);
  if(!ref($plr)) { return "Failed to get player info"; }
  if(!$plr->{'clan_admin'}) { return "Only clan admins can invite players"; }

  #--- create invitiation

  my $invitee = route_parameters->get('invitee');
  my $r = plr_invite($name, $invitee);
  if(!ref($r)) {
    return $r;
  } else {
    redirect '/player';
  }
};


#=============================================================================
#=== revoke invitations ======================================================
#=============================================================================

get '/revoke/:player' => sub {

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- perform revocation

  my $invitee = route_parameters->get('player');
  my $r = plr_revoke_invitations($name, $invitee);
  if(!ref($r)) { return $r; }

  redirect '/player';

};

get '/revoke' => sub {

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- perform revocation

  my $r = plr_revoke_invitations($name);
  if(!ref($r)) { return $r; }

  redirect '/player';

};


#=============================================================================
#=== decline invitations =====================================================
#=============================================================================

get '/decline/:player' => sub {

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- perform decline

  my $invitor = route_parameters->get('player');
  my $r = plr_decline_invitation($name, $invitor);
  if(!ref($r)) { return $r; }

  redirect '/player';

};

get '/decline' => sub {

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- perform decline

  my $invitor = route_parameters->get('player');
  my $r = plr_decline_invitation($name);
  if(!ref($r)) { return $r; }

  redirect '/player';

};


#=============================================================================
#=== accept invitation =======================================================
#=============================================================================

get '/accept/:player' => sub {

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- accept invitation

  my $invitor = route_parameters->get('player');
  my $r = plr_accept_invitation($name, $invitor);
  if(!ref($r)) { return $r; }

  redirect '/player';
};


#=============================================================================
#=== give admin rights =======================================================
#=============================================================================

get '/make_admin' => sub {

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- only for clan admins

  my $plr = plr_info($name);
  if(!ref($plr)) { return "Couldn't find player '$name'"; }
  if(!$plr->{'clan_id'} || !$plr->{'clan_admin'}) {
    return "Only clan admins can give admin rights";
  }
  my $clan = $plr->{'clan_name'};

  #--- find eligible players (ie. clan members without admin)

  my $clans = clan_get_info($clan);
  if(!ref($clans)) { return "Failed to get clan info ($clans)"; }

  my @eligible_players = grep {
    !$clans->{$clan}{$_}{'clan_admin'}
  } sort keys %{$clans->{$clan}};


  template 'make_admin', {
    title => 'Devnull / Make Admin',
    clan => $clan,
    eligible => \@eligible_players,
    rt => '/make_admin'
  };

};


#=============================================================================
#=== give admin rights to a player ===========================================
#=============================================================================

get '/make_admin/:player' => sub {

  my $grantee = route_parameters->get('player');
  my $rt = query_parameters->get('rt');

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- only for clan admins

  my $plr = plr_info($name);
  if(!ref($plr)) { return "Couldn't find player '$name'"; }
  if(!$plr->{'clan_id'} || !$plr->{'clan_admin'}) {
    return "Only clan admins can give admin rights";
  }
  my $clan = $plr->{'clan_name'};

  #--- get clan information about the clan

  my $clan_info = clan_get_info($clan);
  if(!ref($clan_info)) { return "Failed to get clan info ($clan_info)"; }
  if(!exists $clan_info->{$clan}) {
    return "Fatal error while trying to get clan info";
  }
  $clan_info = $clan_info->{$clan};

  #--- get info about the grantee

  my $grantee_info = plr_info($grantee);
  if(!ref($grantee_info)) {
    return "Failed to get player info on $grantee ($grantee_info)";
  }
  if($grantee_info->{'clan_admin'}) {
    return "Player $grantee already is admin";
  }

  #--- give admin rights

  my $r = database->do(
    'UPDATE players SET clan_admin = 1 WHERE players_i = ?', undef,
    $grantee_info->{'players_i'}
  );
  if(!$r) {
    return "Failed to grant admin rights to $grantee ($r)";
  }

  #--- finish

  # FIXME: Change this to clan listing once we have that
  redirect $rt || "/clan/$clan";

};


#=============================================================================
#=== give admin rights to a player ===========================================
#=============================================================================

get '/resign_admin' => sub {

  #--- return page

  my $rt = query_parameters->get('rt');

  #--- only for logged in users

  my $name = session('logname');
  if(!$name) { return "Unauthenticated!"; }

  #--- only for clan admins

  my $plr = plr_info($name, 1);
  if(!ref($plr)) { return "Couldn't find player '$name'"; }
  if(!$plr->{'clan_id'} || !$plr->{'clan_admin'}) {
    return "Only clan admins can give admin rights";
  }
  my $clan = $plr->{'clan_name'};

  #--- the only admin on the team is blocked from resigning

  if($plr->{'sole_admin'}) {
    return "Sole admin for the team cannot resign";
  }

  #--- start database transaction

  my $r = database->begin_work();
  if(!$r) { return "Could not start database transaction"; }

  try {

  #--- perform resignation

    $r = database->do(
      'UPDATE players SET clan_admin = 0 WHERE players_i = ?', undef,
      $plr->{'players_i'}
    );
    if(!$r) {
      die "Failed to remove admin rights for $name ($r)\n";
    }

  #--- drop all given invites

    $r = database->do(
      'DELETE FROM invites WHERE invitor =?', undef,
      $plr->{'players_i'}
    );
    if(!$r) {
      die "Failed to remove invites upon resignation ($r)\n";
    }

  #--- abort transaction

  } catch {
    database->rollback();
    return "Failed to resign admin role ($@)";
  }

  #--- finish successfully

  database->commit();
  redirect $rt || '/player';

};


#=============================================================================
#=== list a clan membership ==================================================
#=============================================================================

get '/clan/:clan' => sub {

  #--- gather info, note, that this page doesn't require user to be logged in

  my $name = session('logname');
  my $clan = route_parameters->get('clan');

  #--- response hash

  my %response;

  #--- load player info

  my ($plr_info, $clan_info);

  if($name) {
    $plr_info = plr_info($name, 1);
    if(!ref($plr_info)) {
      return "Failed to get info on user $name ($plr_info)";
    }
    $response{'name'} = $name;
    $response{'admin'} = $plr_info->{'clan_admin'};
  }

  #--- load clan info

  $clan_info = clan_get_info($clan);
  if(!ref($clan_info)) {
    return "Failed to get info on clan $clan ($clan_info)";
  }
  $response{'title'} = "Devnull / Clan $clan";
  $response{'clan'}{'name'} = $clan;

  #--- list of all players

  my $players_all = $response{'clan'}{'players'} = [
    sort keys %{$clan_info->{$clan}}
  ];

  #--- list of admin players

  my $players_admin = $response{'clan'}{'admins'} = [
    grep {
      $clan_info->{$clan}{$_}{'clan_admin'};
    } sort keys %{$clan_info->{$clan}}
  ];

  #--- list of regular (non-admin) players

  my $players_reg = $response{'clan'}{'regulars'} = [
    grep {
      !$clan_info->{$clan}{$_}{'clan_admin'};
    } sort keys %{$clan_info->{$clan}}
  ];

  #--- attach "actions" to each players

  $response{'actions'} = {};
  if($name) {
    for my $player (@$players_all) {

      # kick, give admin
      if(
        $response{'admin'}
        && grep { $_ eq $player } @$players_reg
      ) {
        push(@{$response{'actions'}{$player}},
          [ "/kick/$player", "Kick" ],
          [ "/make_admin/$player", "Make admin" ]
        );
      }

      # resign admin
      if(
        $response{'admin'}
        && !$plr_info->{'sole_admin'}
        && $player eq $name
      ) {
        push(@{$response{'actions'}{$player}},
          [ '/resign_admin', 'Resign admin' ]
        );
      }

    }
  }

  #--- finish

  template 'clan', \%response;

};


true;
