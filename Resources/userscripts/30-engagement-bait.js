/*
 * 30-engagement-bait.js — heuristic engagement-bait classifier.
 *
 * Encodes the blocking criteria from Resources/userscripts/grading_instructions.txt
 * as regexes, so the common cases are caught for free without spending an LLM call.
 * The numbered comments map to the sections of that document.
 *
 * Same contract as the politics filter: pure text -> {score, matches}, hidden at
 * THRESHOLD (3). STRONG patterns (3) hide on their own; WEAK ones (1) need to stack.
 */
(function () {
    'use strict';

    var THRESHOLD = 3;

    var STRONG = [
        // 1. Clickbait
        /you won'?t believe/i,
        /wait for it\b/i,
        /watch (?:it )?(?:till|until) the end/i,
        /\bchange your life\b/i,
        /(?:i|this) tried .{0,30} so you don'?t have to/i,
        /(?:the|this) .{0,20} nobody (?:is )?talk(?:s|ing) about/i,
        /let that sink in/i,
        /read that again/i,
        // 2. Engagement bait
        /\b(?:rt|retweet|like|comment|reply|bookmark) (?:this )?if\b/i,
        /\bgive me (?:one|1|a single) (?:good )?reason\b/i,
        /\bname (?:one|1|a single)\b/i,
        /\btell me (?:one|1)\b/i,
        /\bdrop (?:a|your) (?:🔥|emoji|handle|link|thoughts)/i,
        /\btag (?:someone|a friend|somebody|your)/i,
        /\bwho else\b/i,
        /\bam i the only one\b/i,
        /\bunpopular opinion\b/i,
        /\bhot take\b/i,
        /\bcontroversial (?:opinion|take)\b/i,
        /\bchange my mind\b/i,
        /\bprove me wrong\b/i,
        /\bfight me\b/i,
        /\bthis or that\b/i,
        /\bwhat'?s the (?:one|first) thing\b/i,
        /\bquote (?:this|tweet) with\b/i,
        /\bcomment(?:s)? below\b/i,
        // 3. Viral trends (examples lifted from grading_instructions.txt)
        /\bchill (?:guy|girl)\b/i,
        /\b20(?:1|2)\d recap(?:ped)?\b/i,
        /\byear in review\b/i,
        /\bif you'?re a (?:man|woman|guy|girl) in your \d0s\b/i,
        /\bnamma bengaluru\b/i,
        /\b(?:zepto|zomato|swiggy|blinkit|dunzo)\b/i,
        /\bcloud kitchen/i,
        /\bfounder'?s office\b/i,
        /\bthe new pm\b/i,
        /\b(?:only|real) \w+ (?:kids )?will (?:remember|get this)\b/i,
        /\bpov\s*:/i,
        /\bnobody:\s/i,
        /\bit'?s giving\b/i,
        // 9. Spam and phishing
        /\bearn \$?\d[\d,]*(?:k)? (?:a|per) (?:week|day|month)\b/i,
        /\bmake money (?:online|from home|fast)\b/i,
        /\bclick (?:here|the link) (?:now|to)/i,
        /\bgiveaway\b/i,
        /\bretweet to (?:win|enter)\b/i,
        /\bfirst \d+ (?:people|followers|replies)\b/i,
        /\bdm (?:me|"?\w+"?) (?:for|and i)/i,
        /\blink in (?:bio|comments|replies)\b/i,
        /\bfollow (?:me )?for more\b/i,
        /\bnot financial advice\b/i,
        // 10. Sensationalism
        /\b(?:this|it) (?:is|was) insane\b/i,
        /\bbreaking\s*:/i,
        /\bhuge if true\b/i,
        /\bgame changer\b/i,
        /\bmind\s?blown\b/i,
        /\bwill change (?:everything|the game)\b/i
    ];

    var WEAK = [
        /\bthread\b/i,
        /🧵/,
        /\b1\/(?:\d{1,2})?\s*$/,
        /\bagree\?/i,
        /\bthoughts\?/i,
        /\byes or no\?/i,
        /\bright\?\s*$/i,
        /\bwhat do you think\?/i,
        /\bfacts\b/i,
        /\bthis\.\s*$/i,
        /\bwent viral\b/i,
        /\bblew up\b/i,
        /\bunderrated\b/i,
        /\bgoated\b/i,
        /\bhere'?s (?:how|why|what)\b/i,
        /\b\d+ (?:things|lessons|reasons|ways|tips|mistakes)\b/i,
        /\bbookmark this\b/i,
        /\bsteal (?:this|my)\b/i,
        /\bfree\b.{0,20}\b(?:template|guide|course|checklist)\b/i,
        /(?:😂|🤣|😭){3,}/,
        /🔥{3,}/,
        /^[^a-z0-9]*[A-Z\s!?.]{25,}[^a-z0-9]*$/   // ALL-CAPS shouting
    ];

    // Exemptions from grading_instructions.txt: genuine questions and launches.
    var EXEMPT = [
        /\b(?:announcing|launching|introducing|shipped|now available|open source(?:d)?)\b/i,
        /\b(?:looking for|any (?:examples|recommendations|pointers)|does anyone know|has anyone)\b/i,
        /\b(?:we'?re hiring|join (?:us|our team)|apply here)\b/i,
        /\b(?:changelog|release notes|v\d+\.\d+|beta|waitlist)\b/i,
        /\b(?:paper|preprint|arxiv|benchmark|documentation|docs)\b/i,
        /\b(?:thread )?below (?:is|are) the (?:notes|slides)\b/i
    ];

    function classify(text) {
        if (!text) return { score: 0, matches: [] };
        var score = 0;
        var matches = [];
        var i, m;

        for (i = 0; i < STRONG.length; i++) {
            m = text.match(STRONG[i]);
            if (m) { score += 3; matches.push(m[0].trim().slice(0, 40)); }
        }
        for (i = 0; i < WEAK.length; i++) {
            m = text.match(WEAK[i]);
            if (m) { score += 1; matches.push(m[0].trim().slice(0, 40)); }
        }
        for (i = 0; i < EXEMPT.length; i++) {
            m = text.match(EXEMPT[i]);
            if (m) { score -= 3; matches.push('-' + m[0].trim().slice(0, 40)); }
        }
        return { score: score, matches: matches };
    }

    var api = (window.__tmac || (window.__tmac = {}));
    if (typeof api.registerFilter === 'function') {
        api.registerFilter({
            name: 'bait',
            label: 'engagement bait',
            threshold: THRESHOLD,
            classify: classify
        });
    }
    (window.__tmacClassifiers || (window.__tmacClassifiers = {})).bait = {
        classify: classify, threshold: THRESHOLD
    };
})();
