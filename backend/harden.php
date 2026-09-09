<?php
// Keep verification enabled when the upstream sends the login cookie.
$path = '/app/src/Spotify.php';
$source = file_get_contents($path);
$source = str_replace('CURLOPT_SSL_VERIFYPEER, 0', 'CURLOPT_SSL_VERIFYPEER, true', $source, $peerCount);
$source = str_replace('CURLOPT_SSL_VERIFYHOST, 0', 'CURLOPT_SSL_VERIFYHOST, 2', $source, $hostCount);
if ($peerCount !== 2 || $hostCount !== 2) {
    throw new RuntimeException('Upstream TLS code changed; review before building.');
}
$source = str_replace('CURLOPT_TIMEOUT, 600', 'CURLOPT_TIMEOUT, 15', $source);
// Add a timeout to every cURL request, including lyric and server-time requests.
$source = str_replace('$ch = curl_init();', '$ch = curl_init(); curl_setopt($ch, CURLOPT_TIMEOUT, 15); curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 5);', $source);
file_put_contents($path, $source);
