// The sign-in page's Show / Hide for the password (a generated one is 20 characters: easier to check than to retype on a
// phone). Public, like the page (Caddy's public paths): nothing here reads or sends anything. Without this script the
// button stays hidden and the field works as before.
"use strict";

document.addEventListener("DOMContentLoaded", () => {
  const input = document.getElementById("password"), btn = document.getElementById("pw-toggle");
  if (!input || !btn) return;
  btn.hidden = false;
  btn.setAttribute("aria-label", "Show password");
  btn.addEventListener("click", () => {
    const show = input.type === "password";
    input.type = show ? "text" : "password";
    btn.textContent = show ? "Hide" : "Show";
    btn.setAttribute("aria-label", show ? "Hide password" : "Show password");
    input.focus();
  });
  // (a password field again as the form posts: a browser's password manager offers to save it as one)
  input.form.addEventListener("submit", () => { input.type = "password"; });
});
