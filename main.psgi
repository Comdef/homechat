use strict;
use warnings;

use Plack::Request;
use Plack::Response;
use JSON qw(encode_json decode_json);
use LWP::UserAgent;
use DBI;
use Try::Tiny;
use Plack::Builder;
use Plack::App::File;

# ---------------- CONFIG ----------------

my $KEYCLOAK_URL   = $ENV{KC_URL} || 'http://192.168.50.113:8080';
my $REALM          = $ENV{KC_REALM} || 'master';
my $CLIENT_ID      = $ENV{KC_CLIENT_ID} || 'sync-service';
my $CLIENT_SECRET  = $ENV{KC_CLIENT_SECRET} || '9HXt8xUlWyE5U3ijiAbkUG4PFuVfVByJ';

my $DB_IP = $ENV{DB_IP} || '192.168.50.112';
my $DB_DSN  = 'dbi:Pg:dbname=homechat;host=' . $DB_IP;
my $DB_USER = $ENV{DB_USER} || 'homechat';
my $DB_PASS = $ENV{DB_PASS} || 'Markes';

# ----------------------------------------

my $ua = LWP::UserAgent->new(timeout => 5);

my $dbh = DBI->connect(
    $DB_DSN,
    $DB_USER,
    $DB_PASS,
    { RaiseError => 1, AutoCommit => 1 }
);

sub json_response {
    my ($status, $data) = @_;
    return [
        $status,
        ['Content-Type' => 'application/json'],
        [ encode_json($data) ]
    ];
}

# ---------------- AUTH -------------------

sub check_token {
    my ($token) = @_;

    my $res = $ua->post(
        "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token/introspect",
        {
            token         => $token,
            client_id     => $CLIENT_ID,
            client_secret => $CLIENT_SECRET,
        }
    );

    return unless $res->is_success;

    my $data = decode_json($res->decoded_content);
    return $data->{active} ? $data : undef;
}

# ---------------- PSGI APP ---------------

my $app = sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    # -------- /login --------
    if ($req->path eq '/login' && $req->method eq 'POST') {

        my $p = $req->parameters;
        my ($login, $password) = @$p{qw/login password/};

        my $res = $ua->post(
            "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token",
            {
                grant_type    => 'password',
                client_id     => $CLIENT_ID,
                client_secret => $CLIENT_SECRET,
                username      => $login,
                password      => $password,
            }
        );

        return json_response(
            $res->code,
            decode_json($res->decoded_content)
        );
    }

    # -------- /user/register --------
    if ($req->path eq '/user/register' && $req->method eq 'POST') {

        my $p = $req->parameters;
        my ($email, $login, $password) = @$p{qw/email login password/};

        my $user_id = $dbh->selectrow_array("SELECT id FROM users WHERE email = ?", undef, $email);
	
#TODO: It's not safe, you can brute force a user list.
	return json_response(201, {
             id     => $user_id,
             status => 'registered'
         }) if ($user_id);
	
        try {
            my $sth = $dbh->prepare(
                'INSERT INTO users (email, login) VALUES (?, ?) RETURNING id'
            );
            $sth->execute($email, $login);
            ($user_id) = $sth->fetchrow_array;
        }
        catch {
            return json_response(500, { error => 'DB error' });
        };

        # Получаем admin token
        my $token_res = $ua->post(
            "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token",
            {
                grant_type    => 'client_credentials',
                client_id     => 'admin-cli',
                client_secret => 'admin-secret',
            }
        );

        my $admin_token = decode_json($token_res->decoded_content)->{access_token};

        # Создание пользователя в Keycloak
        my $kc_res = $ua->post(
            "$KEYCLOAK_URL/admin/realms/$REALM/users",
            'Authorization' => "Bearer $admin_token",
            'Content-Type'  => 'application/json',
            Content         => encode_json({
                username => $login,
                email    => $email,
                enabled  => JSON::true,
                credentials => [{
                    type      => 'password',
                    value     => $password,
                    temporary => JSON::false,
                }],
            })
        );

        return json_response(201, {
            id     => $user_id,
            status => 'registered'
        });
    }


    # -------- /user/get/{id} --------
    if ($req->path =~ m{^/user/get/(\d+)$} && $req->method eq 'GET') {

        my $id = $1;
        my $auth = $req->header('Authorization') || '';
        $auth =~ s/^Bearer //;

        my $token_data = check_token($auth)
            or return json_response(401, { error => 'Unauthorized' });

        my $user = $dbh->selectrow_hashref(
            'SELECT id, email, login FROM users WHERE id = ?',
            undef,
            $id
        );

        return json_response(200, $user || {});
    }

    # -------- /user/search --------
    if ($req->path =~ m{^/user/search$} && $req->method eq 'GET') {
	my $p = $req->parameters;
	my ($last_name, $first_name) =  @$p{qw/last_name first_name/};
	my $search_response = [];

	if ($last_name){
		$search_response = $dbh->selectall_arrayref(
             		"select id, email, username from users where last_name like '%?%'",
             		{Slice=>{}},
             		$last_name
         	);
	}elsif ($first_name){
		
	}
        return json_response(200, $search_response || {});
    }


    return json_response(404, { error => 'Not found' });
};

builder {
    enable "Plack::Middleware::Static",
        path => qr{^/(swagger|favicon\.ico)},
        root => './';

    $app;
};
