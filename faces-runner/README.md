# bottomless-faces

Runs People for [Bottomless](https://github.com/shaunak1206/bottomless) on GitHub Actions: every 6 hours,
`scripts/faces.py` finds the faces in newly backed-up photos and sorts them into people. This repo is deployed from
the bottomless repo by `scripts/faces_cloud.sh deploy`; edit the files there, not here.

It is its own private repo because its secrets (the Worker URL and app token) reach every photo, and anyone with
write access to a repo can read that repo's Actions secrets.

- Scheduled: `.github/workflows/people.yml`, cron `23 */6 * * *` (one job; a few minutes when there is little new)
- Big backlog: Actions → People → Run workflow → shards 4
- Its working file (face embeddings, what it has looked at) is kept in the Worker's R2 bucket (`/v1/faces/state`)
