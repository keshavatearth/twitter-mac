/*
 * 90-boot.js — last script in the injection order; starts the engine once every
 * classifier has registered itself. Injection order is fixed in UserScripts.swift.
 */
(function () {
    'use strict';
    if (!window.__tmac || typeof window.__tmac.start !== 'function') {
        console.warn('[tmac] core not loaded; filters inactive');
        return;
    }
    if (document.body) {
        window.__tmac.start();
    } else {
        document.addEventListener('DOMContentLoaded', function () { window.__tmac.start(); });
    }
})();
