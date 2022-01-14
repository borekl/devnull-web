# /DEV/NULL/NETHACK TRIBUTE CLAN MANAGEMENT

This code started as an attempt at reimplementation of /dev/null/nethack's
central server code. With the tournament
[retirement](https://twitter.com/devnull_nethack/status/908441635746279424)
by Krystal, this never came to fruition. Instead, this code was coopted
for clan management of the replacement tournament -- /dev/null/nethack
Tribute and then the TNNT tournament. The tag 'pre-tribute' marks the last
commit before this event.

**Note: TNNT got a new scoreboard, so this code is no longer maintained.**

## ARCHITECTURE

* Perl Dancer framework
* SQLite as backend storage

## INSTALLATION

Upgrade and configure CPAN.pm to bootstrap local::lib

    perl -MCPAN -e 'upgrade CPAN'

Install required Perl modules

    perl -MCPAN -e 'install Syntax::Keyword::Try'
    perl -MCPAN -e 'install File::Touch'
    perl -MCPAN -e 'install App::Cmd::Setup'
    perl -MCPAN -e 'install Plack::Middleware::Deflater'
    perl -MCPAN -e 'install DBD::SQLite'
    perl -MCPAN -e 'install Dancer2'
    perl -MCPAN -e 'install Dancer2::Plugin::Database'
    perl -MCPAN -e 'install Dancer2::Session::Cookie'

Clone the git repository.

## DEPLOYMENT

For testing, you can fire up the application with Plack, just go into the
Dancer app directory `Devnull-Web` and run:

    plackup -p 5000 bin/app.psgi

Then just point your browser to http://*your_ip*:5000/

For production deployment a suitable application web server is needed.
`start.sh` and `stop.sh` scripts utilizing the
[Starman](http://search.cpan.org/~miyagawa/Starman-0.1000/lib/Starman.pm)
web server are provided. The main user-facing webserver needs to be
configured as a reverse proxy for the application webserver. Example of
Apache 2.4 config:

    <Location /devnull/clanmgmt/>
    ProxyPass         http://localhost:5000/
    ProxyPassReverse  /
    ProxyPreserveHost On
    </Location>


## AUTHOR

You can contact me as *Mandevil* on FreeNode.
