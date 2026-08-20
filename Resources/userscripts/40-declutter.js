/*
 * 40-declutter.js — layout declutter toggles (Filters menu, persisted in UserDefaults).
 *
 *   hideSidebar    hide the right column: trends, who-to-follow, Premium upsell
 *   followingOnly  hide the "For You" home tab and switch to "Following"
 *
 * "hidePromoted" is not here: promoted posts are collapsed by the same pipeline as
 * filtered tweets (10-core.js) so they get the same reveal-on-click bar.
 */
(function () {
    'use strict';

    var STYLE_ID = 'tmac-declutter-style';
    var lastSwitchAt = 0;

    function styleEl() {
        var el = document.getElementById(STYLE_ID);
        if (!el) {
            el = document.createElement('style');
            el.id = STYLE_ID;
            (document.head || document.documentElement).appendChild(el);
        }
        return el;
    }

    function tabs() {
        var scope = document.querySelector('[data-testid="primaryColumn"]');
        if (!scope) return [];
        var found = scope.querySelectorAll('nav[role="navigation"] [role="tab"], [role="tablist"] [role="tab"]');
        return Array.prototype.slice.call(found);
    }

    function pick(list, rx, fallbackIndex) {
        for (var i = 0; i < list.length; i++) {
            if (rx.test((list[i].textContent || '').trim())) return list[i];
        }
        return list[fallbackIndex] || null;
    }

    function applyFollowingOnly(on) {
        var list = tabs();
        if (list.length < 2) return;
        var forYou = pick(list, /^for you$/i, 0);
        var following = pick(list, /^following$/i, 1);
        if (!forYou || !following || forYou === following) return;

        var wrapper = forYou.closest('[role="presentation"]') || forYou;
        wrapper.style.display = on ? 'none' : '';

        // X re-renders the timeline on its own and can re-select "For you"; re-click
        // when that happens, but rate-limit so a fight with X's router can't spin.
        if (on && forYou.getAttribute('aria-selected') === 'true') {
            var now = Date.now();
            if (now - lastSwitchAt > 3000) {
                lastSwitchAt = now;
                following.click();
            }
        }
    }

    function apply(settings) {
        var css = [];
        if (settings.hideSidebar) {
            css.push('[data-testid="sidebarColumn"] { display: none !important; }');
            // Without the right column the header's max-width leaves the feed
            // off-centre; let the primary column keep its own width but centre it.
            css.push('header[role="banner"] ~ div [data-testid="primaryColumn"] { margin: 0 auto !important; }');
        }
        styleEl().textContent = css.join('\n');
        applyFollowingOnly(!!settings.followingOnly);
    }

    function onNavigate(settings) {
        lastSwitchAt = 0;
        apply(settings);
    }

    window.__tmacDeclutter = { apply: apply, onNavigate: onNavigate };
})();
