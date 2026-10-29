/**
 * AirPlayr Website Shared Utilities
 * - Dynamic scroll padding calculation
 * - Browser OS auto-detection for download buttons
 * - Mobile nav drawer toggle
 */

function updateNavOffset() {
  const navWrapper = document.querySelector('.navbar-wrapper');
  if (!navWrapper) return;
  // Scrolled navbar docks at top: 0; offset ensures anchor headings clear the navbar with 14px breathing room
  const offset = navWrapper.offsetHeight + 14;
  document.documentElement.style.setProperty('--nav-offset', offset + 'px');
}

function initNavbarScroll() {
  const navWrapper = document.querySelector('.navbar-wrapper');
  if (!navWrapper) return;

  let ticking = false;
  const onScroll = () => {
    const isScrolled = window.scrollY > 15;
    if (navWrapper.classList.contains('is-scrolled') !== isScrolled) {
      navWrapper.classList.toggle('is-scrolled', isScrolled);
      updateNavOffset();
    }
  };

  window.addEventListener('scroll', () => {
    if (!ticking) {
      window.requestAnimationFrame(() => {
        onScroll();
        ticking = false;
      });
      ticking = true;
    }
  }, { passive: true });

  onScroll();
}

function detectPlatform() {
  const ua = (navigator.userAgent || '').toLowerCase();

  if (/iphone|ipad|ipod/.test(ua)) {
    return {
      name: 'iOS',
      label: 'AirPlayr for iOS (Alpha)',
      file: 'AirPlayrIOS',
      url: 'https://github.com/sarthak7gupta/AirPlayr/tree/alpha',
      meta: 'iOS Companion on alpha branch'
    };
  }
  return {
    name: 'Mac',
    label: 'Download for Mac',
    file: 'AirPlayr-1.6.0.dmg',
    url: 'https://github.com/sarthak7gupta/AirPlayr/releases/download/v1.6.0/AirPlayr-1.6.0.dmg',
    meta: 'Universal macOS .dmg (Apple Silicon & Intel · macOS 14+)'
  };
}

function setupPlatformDownloads() {
  const target = detectPlatform();

  document.querySelectorAll('.platform-download-btn').forEach(btn => {
    btn.href = target.url;
    const textSpan = btn.querySelector('.platform-download-text');
    if (textSpan) {
      textSpan.textContent = target.label;
    } else {
      const span = btn.querySelector('span');
      if (span) span.textContent = target.label;
    }
  });

  const heroSubtext = document.querySelector('.hero-download-subtext');
  if (heroSubtext) {
    heroSubtext.textContent = `Auto-detected for ${target.name} · ${target.meta}`;
  }
}

function initNavToggle() {
  const navToggle = document.getElementById('nav-toggle');
  const dropdown = document.getElementById('nav-menu-dropdown');
  if (navToggle && dropdown) {
    navToggle.addEventListener('click', (e) => {
      e.stopPropagation();
      const isOpen = dropdown.classList.toggle('is-open');
      navToggle.setAttribute('aria-expanded', String(isOpen));
    });

    document.addEventListener('click', (e) => {
      if (!dropdown.contains(e.target) && !navToggle.contains(e.target)) {
        dropdown.classList.remove('is-open');
        navToggle.setAttribute('aria-expanded', 'false');
      }
    });

    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && dropdown.classList.contains('is-open')) {
        dropdown.classList.remove('is-open');
        navToggle.setAttribute('aria-expanded', 'false');
        navToggle.focus();
      }
    });
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => {
    initNavToggle();
    initNavbarScroll();
    updateNavOffset();
    setupPlatformDownloads();
  });
} else {
  initNavToggle();
  initNavbarScroll();
  updateNavOffset();
  setupPlatformDownloads();
}

window.addEventListener('resize', updateNavOffset);
window.addEventListener('load', updateNavOffset);
