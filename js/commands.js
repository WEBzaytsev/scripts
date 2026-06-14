// commands.js — command builder: assembles the curl/bash command for each script.

var REPO        = 'WEBzaytsev/scripts';
var CLEANUP_CMD = 'rm -f -- ./revoke-ssh-keys.sh ~/revoke-ssh-keys.sh /tmp/revoke-ssh-keys.sh /root/revoke-ssh-keys.sh 2>/dev/null';
var JSDELIVR     = 'https://cdn.jsdelivr.net/gh/' + REPO + '@main';
var RAW_GITHUB   = 'https://raw.githubusercontent.com/' + REPO + '/main';

function cacheBust() {
  return Date.now();
}

function jsDelivrUrl(file) {
  return JSDELIVR + '/' + file + '?v=' + cacheBust();
}

function rawUrl(file) {
  return RAW_GITHUB + '/' + file + '?v=' + cacheBust();
}

// Escape a value for embedding inside double-quoted bash argument.
function escBash(str) {
  return str
    .replace(/\\/g, '\\\\')
    .replace(/"/g,  '\\"')
    .replace(/\$/g, '\\$')
    .replace(/`/g,  '\\`');
}

var BUILDERS = {

  'ssh-config': function(v) {
    var url  = jsDelivrUrl('ssh-config.sh');
    var args = [];
    if (v.key && v.key.trim()) args.push('-k "' + escBash(v.key.trim()) + '"');
    if (v.portMode === 'random') args.push('--random-port');
    if (v.portMode === 'fixed' && v.port) args.push('--port ' + parseInt(v.port, 10));
    if (v.yes) args.push('--yes');
    var suffix = args.length ? ' -s -- ' + args.join(' ') : '';
    return 'curl -sSL "' + url + '" | sudo bash' + suffix;
  },

  'revoke-ssh-keys': function(v) {
    if (!v.key || !v.key.trim()) return '';
    var url  = rawUrl('revoke-ssh-keys.sh');
    var args = [];
    args.push('-k "' + escBash(v.key.trim()) + '"');
    if (v.yes) args.push('--yes');
    if (v.killSessions) args.push('--kill-sessions');
    if (v.regenHostKeys) args.push('--regen-host-keys');
    var suffix = args.length ? ' -s -- ' + args.join(' ') : '';
    var run = 'curl -sSL "' + url + '" | sudo bash' + suffix;

    var parts = [];
    if (v.cleanupBefore) parts.push(CLEANUP_CMD);
    parts.push(run);
    if (v.cleanupAfter) parts.push(CLEANUP_CMD);
    return parts.join('; \\\n  ');
  },

  'ssh-keygen': function(v) {
    var email    = (v.email || '').trim();
    var filename = (v.filename || '').trim() || '~/.ssh/id_ed25519';
    var lines = [];
    lines.push('ssh-keygen -t ed25519 -C "' + escBash(email) + '" -f ' + filename);
    lines.push('# Показать публичный ключ:');
    lines.push('cat ' + filename + '.pub');
    return lines.join('\n');
  },

  'docker-aliases': function(v) {
    var url  = jsDelivrUrl('docker-aliases.sh');
    var flag = '';
    if (v.action === 'uninstall') flag = ' -s -- --uninstall';
    if (v.action === 'print')     flag = ' -s -- --print';
    return 'curl -sSL "' + url + '" | sudo bash' + flag;
  },

  'docker-monitor': function(v) {
    var url  = jsDelivrUrl('docker-monitor.sh');
    var args = [];
    if (v.hubUrl && v.hubUrl.trim()) args.push('--hub-url "' + escBash(v.hubUrl.trim()) + '"');
    var suffix = args.length ? ' -s -- ' + args.join(' ') : '';
    return 'curl -sSL "' + url + '" | sudo bash' + suffix;
  },

  'enable-bbr': function() {
    var url = jsDelivrUrl('enable-bbr.sh');
    return 'curl -sSL "' + url + '" | sudo sh';
  },

  'ufw-config': function(v) {
    var url  = jsDelivrUrl('ufw-config.sh');
    var args = [];
    if (v.sshPort && v.sshPort.trim()) args.push('--ssh-port ' + parseInt(v.sshPort.trim(), 10));
    if (!v.https) args.push('--no-https');
    if (!v.xray) args.push('--no-xray');
    if (!v.remnawave) args.push('--no-remnawave');
    if (!v.openvpn) args.push('--no-openvpn');
    if (!v.icmpBlock) args.push('--no-icmp-block');
    if (v.extraPorts && v.extraPorts.trim()) args.push('--extra-ports "' + escBash(v.extraPorts.trim()) + '"');
    if (v.yes) args.push('--yes');
    var suffix = args.length ? ' -s -- ' + args.join(' ') : '';
    return 'curl -sSL "' + url + '" | sudo bash' + suffix;
  },
};

// Build a wget fallback command for scripts that support pipe execution.
var WGET_BUILDERS = {

  'ssh-config': function(v) {
    var url  = jsDelivrUrl('ssh-config.sh');
    var args = [];
    if (v.key && v.key.trim()) args.push('-k "' + escBash(v.key.trim()) + '"');
    if (v.portMode === 'random') args.push('--random-port');
    if (v.portMode === 'fixed' && v.port) args.push('--port ' + parseInt(v.port, 10));
    if (v.yes) args.push('--yes');
    var suffix = args.length ? ' -s -- ' + args.join(' ') : '';
    return 'wget -qO- "' + url + '" | sudo bash' + suffix;
  },

  'enable-bbr': function() {
    var url = jsDelivrUrl('enable-bbr.sh');
    return 'wget -qO- "' + url + '" | sudo sh';
  },
};

function buildCommand(scriptId, values) {
  var builder = BUILDERS[scriptId];
  if (!builder) return '';
  return builder(values || {});
}

function buildWgetCommand(scriptId, values) {
  var builder = WGET_BUILDERS[scriptId];
  if (!builder) return null;
  return builder(values || {});
}

function hasWget(scriptId) {
  return !!WGET_BUILDERS[scriptId];
}
