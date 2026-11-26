# Customer email flows (pilot, disabled by default)

Enable customerAuthEnabled in the dedicated-origin configuration only after configuring email confirmation, signup and recovery email templates with the one-time code, trusted SMTP, rate limits/CAPTCHA and testing real delivery. Never enable on GitHub Pages. A recovery token is held only for the password update and global logout; it is never used as a shopping session. No live Auth setting changed. Provider-side controls and actual email delivery remain required.

Email operations are serialized in the storefront client: registration, confirmation, recovery, and reset cannot overlap another email operation or sign-in, including during recovery-token logout. A failure releases the guard without creating a shopping session. This is a client-side safety measure, not a replacement for provider rate limits or real email verification.
