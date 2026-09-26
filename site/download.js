// Device hints only choose the download presentation. Nothing is sent or stored.
(() => {
  const nav = navigator;
  const ua = nav.userAgent || '';
  const platform = nav.userAgentData?.platform || nav.platform || '';
  const mobile = /iPhone|iPad|iPod|Android/i.test(ua) || (/Mac/i.test(platform) && nav.maxTouchPoints > 1);
  const mac = !mobile && /Mac/i.test(platform);
  const windows = /Win/i.test(platform);
  const linux = !mobile && /Linux/i.test(platform);
  const buttons = document.querySelectorAll('[data-download]');
  const statuses = document.querySelectorAll('[data-download-status]');
  function unavailable(label, message) {
    buttons.forEach(button => {
      button.removeAttribute('href');
      button.setAttribute('role', 'link');
      button.setAttribute('aria-disabled', 'true');
      button.querySelector('[data-download-label]').textContent = label;
    });
    statuses.forEach(status => { status.textContent = message; });
    document.querySelectorAll('.download-options').forEach(options => { options.open = true; });
  }
  if (windows || linux) {
    const os = windows ? 'Windows' : 'Linux';
    unavailable(`${os} version not available yet`, 'Juicebars currently runs on Macs with Apple Silicon.');
  } else if (mobile) {
    unavailable('Available for Mac', 'Open this page on your Mac to install Juicebars.');
  } else if (mac) {
    // Safari's "Intel Mac" user-agent also appears on Apple Silicon. Never use it to infer a CPU.
    statuses.forEach(status => { status.textContent = 'Apple Silicon · macOS 14 or later'; });
    if (nav.userAgentData?.getHighEntropyValues) {
      nav.userAgentData.getHighEntropyValues(['architecture']).then(hints => {
        if (hints.architecture === 'x86') {
          unavailable('Apple Silicon required', 'No Intel build is available. If your browser is running under Rosetta, use the Mac download below.');
        }
      }).catch(() => { /* The clearly labeled Mac download remains available without CPU hints. */ });
    }
  }
})();
