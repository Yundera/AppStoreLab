<?php
// Roundcube store app: settings beyond what the image's environment variables cover.
// Included after the image's own config (files in /var/roundcube/config/).

$config['product_name'] = 'Roundcube';
$config['skin'] = 'elastic';
$config['enable_installer'] = false;

// The login page offers these providers; each one sends through its own SMTP
// server with the same login (an app password where the provider has them).
$config['imap_host'] = [
    'ssl://imap.gmail.com:993'        => 'Gmail',
    'ssl://mail.privateemail.com:993' => 'Namecheap Private Email',
    'ssl://imap.mail.yahoo.com:993'   => 'Yahoo',
    'ssl://imap.mail.me.com:993'      => 'iCloud',
    'ssl://imap.fastmail.com:993'     => 'Fastmail',
];
$config['smtp_host'] = [
    'imap.gmail.com'        => 'ssl://smtp.gmail.com:465',
    'mail.privateemail.com' => 'ssl://mail.privateemail.com:465',
    'imap.mail.yahoo.com'   => 'ssl://smtp.mail.yahoo.com:465',
    'imap.mail.me.com'      => 'tls://smtp.mail.me.com:587',
    'imap.fastmail.com'     => 'ssl://smtp.fastmail.com:465',
];

// The user's own provider, asked at install (PROVIDER_IMAP_HOST / _SMTP_HOST; not
// ROUNDCUBE_*: Roundcube reads ROUNDCUBE_<SETTING> as an override of that setting):
// listed first. Host form: ssl://mail.example.com:993 (tls:// for STARTTLS).
$own_imap = trim((string) getenv('PROVIDER_IMAP_HOST'));
if ($own_imap !== '') {
    $own_smtp = trim((string) getenv('PROVIDER_SMTP_HOST'));
    $own_name = trim((string) getenv('PROVIDER_NAME')) ?: 'My provider';
    $config['imap_host'] = [$own_imap => $own_name] + $config['imap_host'];
    // smtp_host is keyed by the IMAP host without scheme and port
    $key = preg_replace(['#^[a-z]+://#i', '#:\d+$#'], '', $own_imap);
    $config['smtp_host'] = [$key => $own_smtp !== '' ? $own_smtp : 'ssl://' . $key . ':465'] + $config['smtp_host'];
}
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';

$config['login_autocomplete'] = 2;
