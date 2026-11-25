# Customer email flows (pilot, disabled by default)

Enable customerAuthEnabled in the dedicated-origin configuration only after configuring email confirmation, signup and recovery email templates with the one-time code, trusted SMTP, rate limits/CAPTCHA and testing real delivery. Never enable on GitHub Pages. A recovery token is held only for the password update and global logout; it is never used as a shopping session. No live Auth setting changed. Provider-side controls and actual email delivery remain required.
