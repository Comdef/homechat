use strict;
use warnings;

use Plack::Request;
use JSON qw(decode_json encode_json);
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use DBI;
use Time::HiRes qw(time);


# Разрешённые события
my %ALLOWED_EVENTS = map { $_ => 1 } qw(
    REGISTER
    UPDATE_PROFILE
    UPDATE_EMAIL
    DELETE_ACCOUNT
);
# Настройки DB
my $DB_DSN  = 'dbi:Pg:dbname=homechat;host=192.168.50.112';
my $DB_USER = $ENV{DB_USER} || 'homechat';
my $DB_PASS = $ENV{DB_PASS} || 'Markes';

# Настройки Keycloak
my $KEYCLOAK_URL = $ENV{KC_URL} || 'http://192.168.50.113:8080';
my $REALM        = $ENV{KC_REALM} || 'master';
my $CLIENT_ID    = $ENV{KC_CLIENT_ID} || 'sync-service';
my $CLIENT_SECRET= $ENV{KC_CLIENT_SECRET} || '9HXt8xUlWyE5U3ijiAbkUG4PFuVfVByJ';

# GLOBALS 
my $ua = LWP::UserAgent->new(timeout => 5);

my $dbh = DBI->connect(
    $DB_DSN, $DB_USER, $DB_PASS,
    { RaiseError => 1, AutoCommit => 1 }
);


# Кеш токена
my $ADMIN_TOKEN;
my $TOKEN_EXPIRES_AT = 0;

sub get_admin_token {
    # Если токен не просрочен
    return $ADMIN_TOKEN if $ADMIN_TOKEN && time < $TOKEN_EXPIRES_AT;

    my $res = $ua->request(
        POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token",
        Content_Type => 'application/x-www-form-urlencoded',
        Content => {
            grant_type    => 'client_credentials',
            client_id     => $CLIENT_ID,
            client_secret => $CLIENT_SECRET,
        }
    );

    # Логи для отладки
    print STDERR $res->status_line, "\n";
    print STDERR $res->decoded_content, "\n";

    die "Token error" unless $res->is_success;

    my $data = decode_json($res->decoded_content);
    $ADMIN_TOKEN = $data->{access_token};
    $TOKEN_EXPIRES_AT = time + $data->{expires_in} - 30; # 30 сек запас
    return $ADMIN_TOKEN;
}
### ================== KEYCLOAK ==================

sub find_user {
    my ($ref) = @_;

    if ($ref =~ /^[0-9a-f\-]{36}$/i) {
        return fetch_user_by_id($ref);
    }

    my $res = $ua->request(
        GET "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$ref",
        Authorization => "Bearer " . admin_token(),
    );

    return unless $res->is_success;
    my $list = decode_json($res->decoded_content);
    return $list->[0];
}

sub fetch_user_by_id {
    my ($id) = @_;

    my $res = $ua->request(
        GET "$KEYCLOAK_URL/admin/realms/$REALM/users/$id",
        Authorization => "Bearer " . admin_token(),
    );

    return unless $res->is_success;
    return decode_json($res->decoded_content);
}

### ================== DB ==================

sub upsert_user {
    my ($u) = @_;

    my $sql = qq{
        INSERT INTO users (id_keyclock, username, email, first_name, last_name, enabled)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
            username   = EXCLUDED.username,
            email      = EXCLUDED.email,
            first_name = EXCLUDED.first_name,
            last_name  = EXCLUDED.last_name,
            enabled    = EXCLUDED.enabled,
            updated_at = now()
    };

    $dbh->do($sql, undef,
        $u->{id},
        $u->{username},
        $u->{email},
        $u->{firstName},
        $u->{lastName},
        $u->{enabled},
    );
}

sub delete_user {
    my ($id) = @_;
    $dbh->do('DELETE FROM users WHERE id_keyclock = ?', undef, $id);
}

### ================== HTTP ==================

sub json_response {
    my ($status, $data) = @_;
    return [
        $status,
        ['Content-Type' => 'application/json'],
        [ encode_json($data) ]
    ];
}


# Основное приложение PSGI

my $app = sub {
    my $req = Plack::Request->new(shift);

    return json_response(405, { error => 'Method not allowed' })
        unless $req->method eq 'POST';

    my $payload;
    eval { $payload = decode_json($req->content); };
    return json_response(400, { error => 'Invalid JSON' }) if $@;

    my $event = $payload->{type} // '';
    return json_response(200, { status => 'ignored' })
        unless $ALLOWED_EVENTS{$event};

    my $ref = $payload->{userId}
        or return json_response(400, { error => 'userId missing' });

    if ($event eq 'DELETE_ACCOUNT') {
        delete_user($ref);
        return json_response(200, { status => 'deleted' });
    }

    my $user = find_user($ref)
        or return json_response(500, { error => 'User not found' });

    upsert_user($user);

    return json_response(200, {
        status => 'ok',
        user   => {
            id       => $user->{id},
            username => $user->{username},
            email    => $user->{email},
        }
    });
};

$app;

