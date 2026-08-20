/*
 * 20-politics.js — heuristic politics classifier.
 *
 * Pure function of the tweet text: no DOM, no network. Edit the word lists below
 * and hit Filters > Reload Filter Scripts (Cmd-Shift-R) — no rebuild needed.
 *
 * Scoring: every matched pattern adds its weight; the tweet is hidden once the
 * total reaches THRESHOLD (3). So one STRONG term hides a tweet, two MEDIUM terms
 * hide a tweet, and a single MEDIUM term does not. EXEMPT patterns subtract, which
 * is how "conservative estimate" and "liberal arts" stay visible.
 */
(function () {
    'use strict';

    var THRESHOLD = 3;

    // Unambiguously political: one hit is enough.
    var STRONG = [
        // US politics
        'trump', 'maga', 'biden', 'kamala', 'obama', 'desantis', 'newsom', 'aoc',
        'pete buttigieg', 'rfk', 'vivek ramaswamy', 'mitch mcconnell', 'nancy pelosi',
        'republican', 'republicans', 'democrat', 'democrats', 'democratic party', 'gop',
        'white house', 'congress', 'senate', 'house of representatives', 'filibuster',
        'impeach', 'impeachment', 'scotus', 'supreme court', 'electoral college',
        'gerrymander', 'ballot', 'primaries', 'midterms', 'swing state',
        'second amendment', 'gun control', 'roe v wade', 'abortion', 'pro-choice', 'pro-life',
        'deportation', 'deported', 'ice raid', 'border wall', 'illegal immigrants', 'immigration',
        'affirmative action', 'critical race theory', 'defund the police',
        // Indian politics
        'bjp', 'rahul gandhi', 'narendra modi', 'amit shah', 'yogi adityanath',
        'arvind kejriwal', 'mamata banerjee', 'aap government', 'rss',
        'hindutva', 'lok sabha', 'rajya sabha', 'caa', 'nrc', 'article 370',
        'reservation quota', 'ram mandir', 'love jihad',
        // Geopolitics / conflict
        'netanyahu', 'zelensky', 'zelenskyy', 'vladimir putin', 'xi jinping', 'kim jong',
        'gaza', 'hamas', 'hezbollah', 'idf', 'west bank', 'intifada',
        'israel', 'israeli', 'palestine', 'palestinian', 'zionist', 'zionism',
        'ukraine war', 'russian invasion', 'ceasefire', 'war crimes', 'genocide',
        'apartheid', 'ethnic cleansing', 'nato', 'brexit',
        'sanctions on', 'tariffs on', 'trade war',
        // Culture war
        'woke agenda', 'wokeism', 'anti-woke', 'far-right', 'far right', 'alt-right',
        'white supremacy', 'antifa', 'fascism', 'fascist', 'nazi', 'communist regime',
        'cancel culture', 'groomer', 'transgender athletes', 'gender ideology'
    ];

    // Political-ish, but common enough elsewhere that it needs a second signal.
    var MEDIUM = [
        'president', 'prime minister', 'chancellor', 'senator', 'governor', 'mayor',
        'parliament', 'legislation', 'legislature', 'bill passed', 'veto', 'executive order',
        'election', 'elections', 'campaign trail', 'voters', 'voting', 'referendum',
        'left-wing', 'right-wing', 'leftist', 'rightist', 'liberal', 'conservative',
        'socialism', 'socialist', 'communism', 'capitalism is', 'marxist',
        'protest', 'protests', 'protesters', 'rally', 'riot', 'riots', 'uprising',
        'indicted', 'indictment', 'prosecutor', 'attorney general', 'court ruled',
        'regime', 'dictator', 'dictatorship', 'authoritarian', 'propaganda', 'coup',
        'tariff', 'tariffs', 'sanctions', 'geopolitical', 'nationalist', 'nationalism',
        'patriots', 'refugees', 'asylum seekers', 'militant', 'airstrike', 'missile strike',
        '政治'
    ];

    // Phrases that look political to a keyword matcher but are not.
    var EXEMPT = [
        'conservative estimate', 'conservatively', 'liberal arts', 'liberal amount',
        'liberally', 'president of the company', 'vp of', 'election of types',
        'protest against the bug', 'nazi germany documentary', 'campaign email',
        'marketing campaign', 'ad campaign', 'kickstarter campaign', 'email campaign',
        'drip campaign', 'senate house cambridge', 'vote for the best',
        'community rally', 'rally the team', 'protest song'
    ];

    function esc(s) {
        return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    /* Word-boundary-ish matching that still works for terms containing spaces,
       hyphens or CJK. \b misfires next to non-ASCII, so bound on the class of the
       first/last character instead. */
    function build(list) {
        return list.map(function (term) {
            var body = esc(term.toLowerCase());
            var left = /^[a-z0-9]/.test(term.toLowerCase()) ? '(?<![a-z0-9])' : '';
            var right = /[a-z0-9]$/.test(term.toLowerCase()) ? '(?![a-z0-9])' : '';
            return { term: term, re: new RegExp(left + body + right, 'i') };
        });
    }

    var strongRe = build(STRONG);
    var mediumRe = build(MEDIUM);
    var exemptRe = build(EXEMPT);

    function classify(text) {
        if (!text) return { score: 0, matches: [] };
        var hay = text.toLowerCase();
        var score = 0;
        var matches = [];
        var i;

        for (i = 0; i < strongRe.length; i++) {
            if (strongRe[i].re.test(hay)) { score += 3; matches.push(strongRe[i].term); }
        }
        for (i = 0; i < mediumRe.length; i++) {
            if (mediumRe[i].re.test(hay)) { score += 2; matches.push(mediumRe[i].term); }
        }
        for (i = 0; i < exemptRe.length; i++) {
            if (exemptRe[i].re.test(hay)) { score -= 3; matches.push('-' + exemptRe[i].term); }
        }
        return { score: score, matches: matches };
    }

    var api = (window.__tmac || (window.__tmac = {}));
    if (typeof api.registerFilter === 'function') {
        api.registerFilter({
            name: 'politics',
            label: 'politics',
            threshold: THRESHOLD,
            classify: classify
        });
    }
    // Exposed for `TwitterMac selftest`.
    (window.__tmacClassifiers || (window.__tmacClassifiers = {})).politics = {
        classify: classify, threshold: THRESHOLD
    };
})();
