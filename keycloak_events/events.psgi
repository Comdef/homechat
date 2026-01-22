use strict;
use warnings;

use Plack::Request;
use JSON qw(decode_json encode_json);
use LWP::UserAgent;

my %ALLOWED_EVENTS = map { $_ => 1 } qw(
  REGISTER
  UPDATE_PROFILE
  UPDATE_EMAIL
  DELETE_ACCOUNT
);

my $KEYCLOAK_URL   = 'http://192.168.50.113:8080';
my $REALM          = 'main';
my $ADMIN_TOKEN    = get_admin_token('sync-service', '9HXt8xUlWyE5U3ijiAbkUG4PFuVfVByJ');

my $ua = LWP::UserAgent->new(timeout => 5);

sub fetch_user {
    my ($user_id) = @_;

    my $req = HTTP::Request->new(
        GET => "$KEYCLOAK_URL/admin/realms/$REALM/users/$user_id"
    );
    $req->header( Authorization => "Bearer $ADMIN_TOKEN" );

    my $res = $ua->request($req);
    return undef unless $res->is_success;

    return decode_json($res->decoded_content);
}

sub json_response {
    my ($status, $data) = @_;
    return [
        $status,
        ['Content-Type' => 'application/json'],
        [ encode_json($data) ]
    ];
}

sub get_admin_token {
    my $client_id = shift;
    my $client_secret = shift
    my $res = $ua->post(
        "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token",
        {
            grant_type    => 'client_credentials',
            client_id     => $client_id,
            client_secret => $client_secret,
        }
    );

    die "Token error" unless $res->is_success;

    my $data = decode_json($res->decoded_content);
    return $data->{access_token};
}

my $app = sub {
    my $req = Plack::Request->new(shift);

    return json_response(405, { error => 'Method not allowed' })
        unless $req->method eq 'POST';

    my $payload;
    eval {
        $payload = decode_json($req->content);
    };
    return json_response(400, { error => 'Invalid JSON' }) if $@;

    my $event = $payload->{type} // '';
    return json_response(200, { status => 'ignored' })
        unless $ALLOWED_EVENTS{$event};

    my $user_id = $payload->{userId};

    if ($event eq 'DELETE_ACCOUNT') {
        # TODO: delete from users where id = user_id
        warn "DELETE user $user_id\n";
        return json_response(200, { status => 'deleted' });
    }

    my $user = fetch_user($user_id);
    return json_response(500, { error => 'Failed to fetch user' })
        unless $user;

    my %user_row = (
        id         => $user->{id},
        username   => $user->{username},
        email      => $user->{email},
        first_name => $user->{firstName},
        last_name  => $user->{lastName},
        enabled    => $user->{enabled},
    );

    # TODO: UPSERT into users table
    warn "UPSERT user $user_row{username}\n";

    return json_response(200, { status => 'ok' });
};

$app;

