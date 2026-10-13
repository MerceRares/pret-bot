# pret-bot – Ideas for notifications

Goal: get a phone notification (ntfy, topic `rares-preturi`)
- **every day at 12:17** with the current price, and
- **whenever the price changes** (up or down).

---

## Implemented: GitHub Actions (runs in the cloud, PC can be off)

How it works:

1. Every hour at minute 17 (`17 * * * *`) **cron-job.org** starts `.github/workflows/pret.yml`, which runs `pret_bot.rb` on GitHub's servers. (GitHub's own `schedule` was too unreliable – see CHANGES.md.)
2. The bot compares the new price with the one saved in `pret.json`:
   - first run → "Am început să urmăresc produsul…"
   - price changed (up or down) → "Prețul s-a schimbat: 179.99 -> 159.99 lei (-20.0 lei)"
3. On the **12:17** run (Romania time), it also sends "Prețul de azi: … lei" (title "Raport zilnic").
4. The workflow commits `pret.json` back to the repo so the next run remembers the last price.

What was changed in `pret_bot.rb`:

- `notifica(mesaj, titlu = "Pret schimbat")` – the title is now a parameter.
- `pret_nou < pret_vechi` → `pret_nou != pret_vechi` – notifies on any change.
- `if Time.now.hour == 12` – sends the daily report (the run at 12:17).

Notes:

- The workflow sets `TZ: Europe/Bucharest`, so `Time.now` is Romania time and summer/winter time is handled automatically.
- You can run it manually anytime: repo → **Actions** → **pret-bot** → **Run workflow**.

## Alternative: Windows Task Scheduler (runs on your PC)

Create a task that runs `bundle exec ruby pret_bot.rb` in this folder **every hour at minute 17**. The 12:17 report works the same way. Downside: the PC must be on.

## More ideas

- **Watch several products**: put a list of URLs in a `produse.json` file and loop over them.
- **Price history**: save every price with its date in `istoric.json`, and send the lowest price ever in the daily report.
- **Target price**: notify only when the price goes under a value you choose (e.g. `PRET_TINTA = 150`).
- **Error alerts**: if the page can't be downloaded or the selector stops working, send a notification "Bot-ul nu a găsit prețul" so you know it's broken.
- **Private topic**: the repo is public, so anyone can see the topic `rares-preturi` and send you messages. Move the topic to a secret: in the workflow add `NTFY_TOPIC: ${{ secrets.NTFY_TOPIC }}` under `env`, and pick a harder-to-guess name.
