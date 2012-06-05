package Guita::Model::Pick;
use strict;
use warnings;

use Guita::Utils qw(now);
use DateTime;
use DateTime::Format::MySQL;
use Encode;

use Class::Accessor::Lite (
    new => 1,
    rw => [qw(
        uuid
        user_id
        star_count
    )],
);

sub created {
    my ($self) = @_;
    my $ret;
    eval {
        $ret = DateTime::Format::MySQL->parse_datetime($self->{created})->set_time_zone('local');
    };
    $ret || now();
}

sub modified {
    my ($self, $modified) = @_;
    if ($modified) {
        $self->{modified} = DateTime::Format::MySQL->format_datetime($modified);
    }
    my $ret;
    eval {
        $ret = DateTime::Format::MySQL->parse_datetime($self->{modified})->set_time_zone('local');
    };
    $ret || now();
}

sub description {
    my ($self, $description) = @_;
    $self->{description} = $description if $description;

    decode_utf8($self->{description});
}

1;
