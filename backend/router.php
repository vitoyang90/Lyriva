<?php
// Never serve source files or expose the upstream endpoint without authentication.
ini_set('display_errors', '0');
ini_set('default_socket_timeout', '10');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
function fail_request(int $status, string $message): never {
    http_response_code($status);
    echo json_encode(['error' => true, 'message' => $message]);
    exit;
}
if ($_SERVER['REQUEST_METHOD'] !== 'GET') { fail_request(405, 'GET required'); }
$key = getenv('LYRICS_API_KEY');
if (!$key || !getenv('SP_DC')) { fail_request(503, 'Server configuration required'); }
if (!hash_equals('Bearer ' . $key, $_SERVER['HTTP_AUTHORIZATION'] ?? '')) {
    fail_request(401, 'Unauthorized');
}
$track = $_GET['trackid'] ?? '';
if (!is_string($track) || !preg_match('/^[a-zA-Z0-9]{22}$/D', $track)) {
    fail_request(400, 'Valid trackid required');
}
require '/app/vendor/autoload.php';
try {
    $spotify = new SpotifyLyricsApi\Spotify(getenv('SP_DC'));
    $spotify->checkTokenExpire();
    $response = $spotify->getLyrics($track);
    echo json_encode(['error' => false, 'syncType' => $response['lyrics']['syncType'],
        'lines' => $response['lyrics']['lines']], JSON_THROW_ON_ERROR);
} catch (Throwable $error) {
    // Do not return upstream exceptions or credential-bearing responses to clients.
    $code = (int) $error->getCode();
    fail_request(in_array($code, [401, 403, 404, 429], true) ? $code : 502, 'Lyrics unavailable');
}
