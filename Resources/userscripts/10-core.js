/*
 * 10-core.js — filtering engine.
 *
 * Ported from the "Twitter Politics Filter" Chrome MV3 extension
 * (content.js + debug_utils.js). Differences from the original, on purpose:
 *
 *   - Blocked tweets collapse to a thin clickable bar instead of getting a red
 *     "content blocked" overlay slapped on top. Nothing is ever removed from the
 *     DOM, so a false positive is one click away from being read.
 *   - Verdicts are cached by tweet ID, so scrolling past the same tweet twice
 *     (X recycles timeline nodes) never re-grades it.
 *   - The LLM call lives on the Swift side (see GeminiGrader.swift). The API key
 *     never enters page context, which also dodges x.com's CSP on
 *     generativelanguage.googleapis.com.
 *
 * This file owns all DOM work. Classifiers (20-politics.js, 30-engagement-bait.js)
 * are pure text -> {score, matches} functions so they can be unit-tested headlessly
 * via `TwitterMac selftest`.
 */
(function () {
    'use strict';

    if (window.__tmac && window.__tmac.installed) return;

    var TWEET_SELECTOR = 'article[data-testid="tweet"]';
    var CELL_SELECTOR = '[data-testid="cellInnerDiv"]';

    var settings = Object.assign({
        politicsEnabled: true,
        baitEnabled: true,
        llmEnabled: false,
        hidePromoted: true,
        hideSidebar: false,
        followingOnly: false,
        debug: false,
        llmMaxPerSession: 200
    }, window.__tmacSettings || {});

    var filters = [];            // [{ name, label, classify(text) -> {score,matches}, threshold, enabled() }]
    var verdicts = new Map();    // tweetId -> { reason, detail } | { reason: null }
    var llmPending = new Set();  // tweetId -> awaiting native verdict
    var llmAsked = 0;

    var stats = { scanned: 0, hidden: 0, byReason: {} };
    var statsDirty = false;

    // ---------------------------------------------------------------- utilities

    function log() {
        if (!settings.debug) return;
        var args = ['%c[tmac]', 'color:#fff;background:#1d9bf0;padding:1px 4px;border-radius:3px'];
        console.log.apply(console, args.concat(Array.prototype.slice.call(arguments)));
    }

    function native(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tmac) {
                window.webkit.messageHandlers.tmac.postMessage(payload);
            }
        } catch (e) { /* running outside the app shell */ }
    }

    function pushStats() {
        if (!statsDirty) return;
        statsDirty = false;
        native({ type: 'stats', scanned: stats.scanned, hidden: stats.hidden, byReason: stats.byReason });
    }
    setInterval(pushStats, 600);

    function bump(reason) {
        stats.hidden += 1;
        stats.byReason[reason] = (stats.byReason[reason] || 0) + 1;
        statsDirty = true;
    }

    // ------------------------------------------------------------ tweet reading

    function tweetId(article) {
        var links = article.querySelectorAll('a[href*="/status/"]');
        for (var i = 0; i < links.length; i++) {
            var m = (links[i].getAttribute('href') || '').match(/\/status\/(\d+)/);
            if (m) return m[1];
        }
        return null;
    }

    /* Tweet body + quoted body + link-card headline. The extension only read
       [data-testid="tweetText"]; cards and quotes carry plenty of the bait. */
    function tweetText(article) {
        var parts = [];
        var bodies = article.querySelectorAll('[data-testid="tweetText"]');
        for (var i = 0; i < bodies.length; i++) parts.push(bodies[i].textContent || '');
        var card = article.querySelector('[data-testid^="card.layout"]');
        if (card) parts.push(card.textContent || '');
        return parts.join('\n').replace(/\s+/g, ' ').trim();
    }

    function isPromoted(article) {
        if (article.querySelector('[data-testid="placementTracking"]')) return true;
        // X renders the "Ad" / "Promoted" label as a bare span in the header row.
        var spans = article.querySelectorAll('div[dir="ltr"] > span, span');
        for (var i = 0; i < spans.length; i++) {
            var t = (spans[i].textContent || '').trim();
            if (t === 'Ad' || t === 'Promoted' || t === 'Promoted by') return true;
        }
        return false;
    }

    // -------------------------------------------------------------- collapse UI

    function ensureStyle() {
        if (document.getElementById('tmac-style')) return;
        var css = [
            '.tmac-collapsed > *:not(.tmac-bar) { display: none !important; }',
            '.tmac-bar {',
            '  display: flex; align-items: center; gap: 8px;',
            '  min-height: 26px; padding: 4px 16px; box-sizing: border-box;',
            '  font: 12px/1.3 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;',
            '  color: rgb(113, 118, 123);',
            '  border-bottom: 1px solid rgba(113, 118, 123, 0.28);',
            '  cursor: pointer; user-select: none;',
            '}',
            '.tmac-bar:hover { color: rgb(29, 155, 240); }',
            '.tmac-bar .tmac-dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; opacity: .7; flex: 0 0 auto; }',
            '.tmac-bar .tmac-why { opacity: .65; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }',
            '.tmac-revealed > .tmac-bar { border-bottom-style: dashed; }'
        ].join('\n');
        var el = document.createElement('style');
        el.id = 'tmac-style';
        el.textContent = css;
        (document.head || document.documentElement).appendChild(el);
    }

    function collapse(container, reason, detail) {
        ensureStyle();
        var bar = container.querySelector(':scope > .tmac-bar');
        if (!bar) {
            bar = document.createElement('div');
            bar.className = 'tmac-bar';
            var dot = document.createElement('span');
            dot.className = 'tmac-dot';
            var label = document.createElement('span');
            label.className = 'tmac-label';
            var why = document.createElement('span');
            why.className = 'tmac-why';
            bar.appendChild(dot);
            bar.appendChild(label);
            bar.appendChild(why);
            bar.addEventListener('click', function (ev) {
                ev.preventDefault();
                ev.stopPropagation();
                toggle(container);
            });
            container.insertBefore(bar, container.firstChild);
        }
        container.dataset.tmacReason = reason;
        container.dataset.tmacDetail = detail || '';
        container.classList.add('tmac-collapsed');
        container.classList.remove('tmac-revealed');
        paint(container);
    }

    function paint(container) {
        var bar = container.querySelector(':scope > .tmac-bar');
        if (!bar) return;
        var reason = container.dataset.tmacReason || 'filtered';
        var detail = container.dataset.tmacDetail || '';
        var revealed = container.classList.contains('tmac-revealed');
        bar.querySelector('.tmac-label').textContent =
            (revealed ? 'shown (' : 'hidden (') + reason + ')';
        bar.querySelector('.tmac-why').textContent =
            revealed ? '— click to hide again' : (detail ? '— ' + detail : '');
        bar.title = detail ? reason + ': ' + detail : reason;
    }

    function toggle(container) {
        var revealed = container.classList.toggle('tmac-revealed');
        container.classList.toggle('tmac-collapsed', !revealed);
        paint(container);
    }

    // ------------------------------------------------------------- registration

    function registerFilter(spec) {
        filters.push(spec);
        log('registered filter', spec.name);
    }

    function activeFilters() {
        return filters.filter(function (f) {
            if (f.name === 'politics') return settings.politicsEnabled;
            if (f.name === 'bait') return settings.baitEnabled;
            return true;
        });
    }

    // ------------------------------------------------------------------ pipeline

    function classify(text) {
        var list = activeFilters();
        for (var i = 0; i < list.length; i++) {
            var f = list[i];
            var r = f.classify(text) || { score: 0, matches: [] };
            if (r.score >= f.threshold) {
                return { reason: f.label, detail: (r.matches || []).slice(0, 3).join(', ') };
            }
        }
        return null;
    }

    function processArticle(article) {
        var container = article.closest(CELL_SELECTOR) || article;
        var id = tweetId(article);

        // X recycles cell nodes while scrolling: re-run when the id underneath changes.
        if (container.dataset.tmacDone === '1' && container.dataset.tmacId === (id || '')) return;

        var text = tweetText(article);
        if (!text && !isPromoted(article)) return;   // header-only / skeleton node, wait for content

        container.dataset.tmacDone = '1';
        container.dataset.tmacId = id || '';
        stats.scanned += 1;
        statsDirty = true;

        if (settings.hidePromoted && isPromoted(article)) {
            collapse(container, 'promoted', '');
            bump('promoted');
            return;
        }

        if (id && verdicts.has(id)) {
            var cached = verdicts.get(id);
            if (cached && cached.reason) {
                collapse(container, cached.reason, cached.detail);
                bump(cached.reason);
            }
            return;
        }

        var hit = classify(text);
        if (hit) {
            if (id) verdicts.set(id, hit);
            collapse(container, hit.reason, hit.detail);
            bump(hit.reason);
            return;
        }

        if (id) verdicts.set(id, { reason: null });

        // Heuristics said "fine". Optionally get a second opinion from the LLM.
        if (settings.llmEnabled && id && !llmPending.has(id) && llmAsked < settings.llmMaxPerSession) {
            llmPending.add(id);
            llmAsked += 1;
            native({ type: 'grade', id: id, text: text.slice(0, 1200) });
        }
    }

    /* Native -> page callback for LLM verdicts. Applies to every cell currently
       showing that tweet id, and caches so later cells reuse it. */
    function onVerdict(v) {
        llmPending.delete(v.id);
        var record = v.blocked ? { reason: 'llm', detail: v.detail || 'graded blocked' } : { reason: null };
        verdicts.set(v.id, record);
        if (!v.blocked) return;
        var cells = document.querySelectorAll('[data-tmac-id="' + v.id + '"]');
        for (var i = 0; i < cells.length; i++) {
            if (cells[i].classList.contains('tmac-collapsed') || cells[i].classList.contains('tmac-revealed')) continue;
            collapse(cells[i], record.reason, record.detail);
            bump(record.reason);
        }
    }

    function scan(root) {
        var node = root || document;
        if (node.nodeType === 1 && node.matches && node.matches(TWEET_SELECTOR)) processArticle(node);
        var found = node.querySelectorAll ? node.querySelectorAll(TWEET_SELECTOR) : [];
        for (var i = 0; i < found.length; i++) processArticle(found[i]);
    }

    var rescanQueued = false;
    function queueRescan() {
        if (rescanQueued) return;
        rescanQueued = true;
        requestAnimationFrame(function () {
            rescanQueued = false;
            scan(document);
            if (window.__tmacDeclutter) window.__tmacDeclutter.apply(settings);
        });
    }

    function start() {
        ensureStyle();
        var observer = new MutationObserver(function (mutations) {
            for (var i = 0; i < mutations.length; i++) {
                var added = mutations[i].addedNodes;
                for (var j = 0; j < added.length; j++) {
                    if (added[j].nodeType !== 1) continue;
                    scan(added[j]);
                }
            }
            // Text can stream into an already-seen skeleton node; a cheap coalesced
            // full rescan catches those without re-running per mutation.
            queueRescan();
        });
        observer.observe(document.documentElement, { childList: true, subtree: true });

        // X is a client-side SPA: no new document load between routes.
        ['pushState', 'replaceState'].forEach(function (fn) {
            var orig = history[fn];
            history[fn] = function () {
                var r = orig.apply(this, arguments);
                window.dispatchEvent(new Event('tmac:navigate'));
                return r;
            };
        });
        window.addEventListener('popstate', function () { window.dispatchEvent(new Event('tmac:navigate')); });
        window.addEventListener('tmac:navigate', function () {
            if (window.__tmacDeclutter) window.__tmacDeclutter.onNavigate(settings);
            queueRescan();
        });

        scan(document);
        if (window.__tmacDeclutter) window.__tmacDeclutter.apply(settings);
        native({ type: 'ready', href: location.href });
        log('engine started', settings);
    }

    function applySettings(next) {
        var prev = settings;
        settings = Object.assign({}, settings, next || {});
        // Turning a filter off must un-hide what it hid; the cheapest correct way is
        // to drop every mark and re-run, since a re-run re-hides anything still matched.
        if (prev.politicsEnabled !== settings.politicsEnabled ||
            prev.baitEnabled !== settings.baitEnabled ||
            prev.hidePromoted !== settings.hidePromoted) {
            resetMarks();
        }
        if (window.__tmacDeclutter) window.__tmacDeclutter.apply(settings);
        queueRescan();
        log('settings applied', settings);
    }

    function resetMarks() {
        verdicts.clear();
        stats.hidden = 0;
        stats.scanned = 0;
        stats.byReason = {};
        statsDirty = true;
        var cells = document.querySelectorAll('[data-tmac-done="1"]');
        for (var i = 0; i < cells.length; i++) {
            var c = cells[i];
            c.classList.remove('tmac-collapsed', 'tmac-revealed');
            var bar = c.querySelector(':scope > .tmac-bar');
            if (bar) bar.remove();
            delete c.dataset.tmacDone;
            delete c.dataset.tmacId;
            delete c.dataset.tmacReason;
            delete c.dataset.tmacDetail;
        }
    }

    function revealAll() {
        var cells = document.querySelectorAll('.tmac-collapsed');
        for (var i = 0; i < cells.length; i++) {
            cells[i].classList.remove('tmac-collapsed');
            cells[i].classList.add('tmac-revealed');
            paint(cells[i]);
        }
    }

    window.__tmac = {
        installed: true,
        version: 1,
        registerFilter: registerFilter,
        settings: function () { return settings; },
        applySettings: applySettings,
        onVerdict: onVerdict,
        start: start,
        rescan: queueRescan,
        reset: resetMarks,
        revealAll: revealAll,
        stats: function () { return JSON.parse(JSON.stringify(stats)); },
        // Console helper, mirrors the extension's window.debugTwitterPolitics.
        debugStats: function () {
            console.group('%cTwitterMac filter stats', 'color:#fff;background:#1d9bf0;padding:2px 6px;border-radius:3px');
            console.log('scanned:', stats.scanned);
            console.log('hidden:', stats.hidden, stats.byReason);
            console.log('cached verdicts:', verdicts.size, '| llm asked:', llmAsked);
            console.groupEnd();
        }
    };
    window.debugTwitterPolitics = window.__tmac.debugStats;
})();
