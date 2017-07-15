#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";


# use this block if you don't need middleware, and only have a single target Dancer app to run here
use Devnull::Web;

Devnull::Web->to_app;

use Plack::Builder;

builder {
    enable 'Deflater';
    Devnull::Web->to_app;
}



=begin comment
# use this block if you want to include middleware such as Plack::Middleware::Deflater

use Devnull::Web;
use Plack::Builder;

builder {
    enable 'Deflater';
    Devnull::Web->to_app;
}

=end comment

=cut

=begin comment
# use this block if you want to include middleware such as Plack::Middleware::Deflater

use Devnull::Web;
use Devnull::Web_admin;

builder {
    mount '/'      => Devnull::Web->to_app;
    mount '/admin'      => Devnull::Web_admin->to_app;
}

=end comment

=cut

