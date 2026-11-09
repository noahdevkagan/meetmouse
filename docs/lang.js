(function() {
  var LANG_NAMES = {
    'en': 'English',
    'pt-br': 'Português',
    'pt': 'Português',
    'es': 'Español'
  };

  function getSupported() {
    var links = document.querySelectorAll('link[rel="alternate"][hreflang]');
    var map = {};
    for (var i = 0; i < links.length; i++) {
      var l = links[i].getAttribute('hreflang');
      var href = links[i].getAttribute('href');
      if (l && href && l !== 'x-default') {
        var norm = l.toLowerCase();
        map[norm] = href;
      }
    }
    return map;
  }

  function findMatch(supported, code) {
    if (!code) return null;
    var norm = code.toLowerCase();
    if (supported[norm]) return supported[norm];
    var prefix = norm.split('-')[0];
    if (supported[prefix]) return supported[prefix];
    for (var k in supported) {
      if (k.split('-')[0] === prefix) return supported[k];
    }
    return null;
  }

  function toRelative(urlStr) {
    if (!urlStr) return urlStr;
    if (urlStr.indexOf('file://') === 0) return urlStr;
    try {
      var parsed = new URL(urlStr, window.location.href);
      if (window.location.protocol === 'file:') {
        var currPath = window.location.pathname;
        var docsIdx = currPath.indexOf('/docs/');
        var basePath = docsIdx !== -1 ? currPath.substring(0, docsIdx + 6) : '';
        var p = parsed.pathname;
        var pDocsIdx = p.indexOf('/docs/');
        if (pDocsIdx !== -1) {
          p = p.substring(pDocsIdx + 6);
        }
        var tgtPath = p.replace(/^\//, '');
        if (tgtPath === '' || tgtPath.endsWith('/')) {
          tgtPath += 'index.html';
        } else if (!tgtPath.endsWith('.html')) {
          tgtPath += '.html';
        }
        return 'file://' + basePath + tgtPath;
      }
      return parsed.pathname + parsed.search + parsed.hash;
    } catch (e) {
      return urlStr;
    }
  }

  function fixFileLinks() {
    if (window.location.protocol !== 'file:') return;
    var currPath = window.location.pathname;
    var docsIdx = currPath.indexOf('/docs/');
    if (docsIdx === -1) return;
    var basePath = 'file://' + currPath.substring(0, docsIdx + 6);
    var links = document.querySelectorAll('a[href^="/"]');
    for (var i = 0; i < links.length; i++) {
      var a = links[i];
      var href = a.getAttribute('href');
      if (!href || href.indexOf('//') === 0 || href.indexOf('mailto:') === 0) continue;
      var clean = href.replace(/^\/+/, '');
      if (clean === 'get') {
        a.href = 'https://meetmouse.com/get';
      } else if (clean === '' || clean.endsWith('/')) {
        a.href = basePath + clean + 'index.html';
      } else if (!clean.endsWith('.html') && clean.indexOf('#') === -1 && clean.indexOf('?') === -1) {
        a.href = basePath + clean + '.html';
      } else {
        a.href = basePath + clean;
      }
    }
    var imgs = document.querySelectorAll('img[src^="/"]');
    for (var j = 0; j < imgs.length; j++) {
      var isrc = imgs[j].getAttribute('src');
      if (isrc && isrc.indexOf('//') !== 0) {
        imgs[j].src = basePath + isrc.replace(/^\/+/, '');
      }
    }
    var icons = document.querySelectorAll('link[rel*="icon"][href^="/"]');
    for (var k = 0; k < icons.length; k++) {
      var ihref = icons[k].getAttribute('href');
      if (ihref && ihref.indexOf('//') !== 0) {
        icons[k].href = basePath + ihref.replace(/^\/+/, '');
      }
    }
  }

  window.MeetMouseLang = {
    detectAndRedirect: function() {
      var currPath = window.location.pathname;
      var isExplicitLang = currPath.indexOf('/br/') !== -1 || currPath.indexOf('/es/') !== -1 ||
                           currPath.endsWith('/br') || currPath.endsWith('/es');
      if (isExplicitLang) {
        var docLang = document.documentElement.lang;
        if (docLang && docLang !== 'en') {
          try { localStorage.setItem('preferred_lang', docLang); } catch (e) {}
        }
        return;
      }

      var supported = getSupported();
      var prefLang = null;
      try {
        prefLang = localStorage.getItem('preferred_lang');
      } catch (e) {}

      if (prefLang === 'en') {
        return;
      }

      var target = null;
      if (prefLang) {
        target = findMatch(supported, prefLang);
      } else {
        try {
          if (sessionStorage.getItem('lang_redirected')) return;
        } catch (e) {}
        var userLangs = navigator.languages || [navigator.language || ''];
        for (var i = 0; i < userLangs.length; i++) {
          var m = findMatch(supported, userLangs[i]);
          if (m) { target = m; break; }
        }
      }

      if (target) {
        var relTarget = toRelative(target);
        var curr = window.location.href.split('#')[0].split('?')[0].replace(/\/+$/, '');
        var tgt = relTarget.split('#')[0].split('?')[0].replace(/\/+$/, '');
        if (tgt && tgt !== curr) {
          try { sessionStorage.setItem('lang_redirected', 'true'); } catch (e) {}
          window.location.replace(relTarget);
        }
      }
    }
  };

  MeetMouseLang.detectAndRedirect();

  document.addEventListener('change', function(e) {
    var sel = e.target && e.target.closest ? e.target.closest('select.lang-select') : null;
    if (!sel) return;
    var opt = sel.options[sel.selectedIndex];
    if (!opt) return;
    var langCode = opt.getAttribute('data-lang') || 'en';
    try { localStorage.setItem('preferred_lang', langCode); } catch (err) {}
    var targetUrl = opt.value;
    if (targetUrl) {
      window.location.href = toRelative(targetUrl);
    }
  });

  document.addEventListener('click', function(e) {
    var a = e.target && e.target.closest ? e.target.closest('a') : null;
    if (!a) return;
    if (a.classList.contains('en-version') || a.getAttribute('hreflang') === 'en') {
      try { localStorage.setItem('preferred_lang', 'en'); } catch (err) {}
    } else {
      var hreflang = a.getAttribute('hreflang');
      if (hreflang && hreflang !== 'en') {
        try { localStorage.setItem('preferred_lang', hreflang); } catch (err) {}
      }
    }
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', fixFileLinks);
  } else {
    fixFileLinks();
  }
})();
