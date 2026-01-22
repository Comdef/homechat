use strict;
use warnings;

use Plack::Request;
use JSON qw(decode_json encode_json);
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);

# Разрешённые события
my %ALLOWED_EVENTS = map { $_ => 1 } qw(
    REGISTER
    UPDATE_PROFILE
    UPDATE_EMAIL
    DELETE_ACCOUNT
);

# Настройки Keycloak
my $KEYCLOAK_URL = $ENV{KC_URL} || 'http://192.168.50.113:8080';
my $REALM        = $ENV{KC_REALM} || 'master';
my $CLIENT_ID    = $ENV{KC_CLIENT_ID} || 'sync-service';
my $CLIENT_SECRET= $ENV{KC_CLIENT_SECRET} || '9HXt8xUlWyE5U3ijiAbkUG4PFuVfVByJ';

# LWP
my $ua = LWP::UserAgent->new(timeout => 5);

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

# Получение пользователя по username
sub fetch_user {
    my ($username) = @_;
    my $req = HTTP::Request->new(
        GET => "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$username"
    );
    $req->header( Authorization => "Bearer " . get_admin_token() );

    my $res = $ua->request($req);
    return undef unless $res->is_success;

    my $users = decode_json($res->decoded_content);
    return undef unless @$users;  # если пустой массив

    return $users->[0];  # первый найденный
}

# Формирование JSON-ответа
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

    # Разрешены только POST
    return json_response(405, { error => 'Method not allowed' })
        unless $req->method eq 'POST';

    my $payload;
    eval { $payload = decode_json($req->content); };
    return json_response(400, { error => 'Invalid JSON' }) if $@;

    my $event = $payload->{type} // '';
    return json_response(200, { status => 'ignored' })
        unless $ALLOWED_EVENTS{$event};

    my $username = $payload->{userId} // '';
    return json_response(400, { error => 'Missing userId' }) unless $username;

    if ($event eq 'DELETE_ACCOUNT') {
        # TODO: удалить пользователя из вашей БД
        warn "DELETE user $username\n";
        return json_response(200, { status => 'deleted' });
    }

    # Получаем пользователя из Keycloak
    my $user = fetch_user($username);
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

    # TODO: UPSERT в вашу таблицу users
    warn "UPSERT user $user_row{username}\n";

    return json_response(200, { status => 'ok', user => \%user_row });
};

$app;

