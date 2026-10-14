# pret-bot – What was done and why

This document explains the work done on **pret-bot**, step by step. It's written for a junior programmer joining the project, so it explains the "why" behind each change, not only the "what".

---

## 1. What the bot does

`pret_bot.rb` watches the price of one product on sportvision.ro and sends a notification to a phone when something interesting happens.

It works in 5 steps:

1. **Download the page** – `descarca_pagina` uses `HTTParty` to fetch the product page's HTML.
2. **Extract the price** – `extrage_pret` uses `Nokogiri` (an HTML parser) to find the price:
   - first it looks for a hidden tag `<meta itemprop="price">`, which has a clean number;
   - if that's missing, it reads the visible text (e.g. `"179,99"`) using the CSS selector `.current-price .product-price-value` and converts it to a number (`179.99`).
3. **Read the old price** – `citeste_pret_vechi` reads the last known price from `pret.json`.
4. **Compare and notify** – if something changed, `notifica` sends a message through **ntfy.sh**.
5. **Save the new price** – `salveaza_pret` writes the new price to `pret.json` for the next run.

### How notifications work (ntfy.sh)

[ntfy.sh](https://ntfy.sh) is a free service. You send an HTTP POST to `https://ntfy.sh/<topic>`, and every phone subscribed to that topic in the ntfy app gets a notification. There's no account and no API key: **the topic name is the only "password"**.

```ruby
Net::HTTP.post(URI("https://ntfy.sh/rares-preturi"), "message text", { "Title" => "..." })
```

---

## 2. Problems found and how they were fixed

### Problem 1: no notification on the phone

**Symptom:** the bot ran fine, but nothing arrived on the phone.

**Debugging:** instead of guessing, we asked ntfy directly which messages it had received on the topic:

```
https://ntfy.sh/rares-pret-k8x2m9/json?poll=1&since=24h
```

The message was there, so the **code worked**. The problem was elsewhere: the phone was subscribed to `rares-preturi`, but the code was sending to `rares-pret-k8x2m9`.

**Fix:** change the topic in `pret_bot.rb`:

```ruby
NTFY_TOPIC = ENV.fetch("NTFY_TOPIC", "rares-preturi")
```

`ENV.fetch("NTFY_TOPIC", "rares-preturi")` means: use the `NTFY_TOPIC` environment variable if it's set, otherwise use `"rares-preturi"`.

> **Lesson:** when "nothing happens", check each step separately (did the code send it? did the server receive it? is the phone listening?). That way you find the broken link in the chain instead of guessing.

### Problem 2: it only notified when the price went down

The goal was to be notified about **any** price change. The original code was:

```ruby
elsif pret_nou < pret_vechi   # only drops
```

**Fix:** use `!=` (different), and show whether the price went up or down:

```ruby
elsif pret_nou != pret_vechi
  diferenta = (pret_nou - pret_vechi).round(2)
  semn = diferenta > 0 ? "+" : ""
  notifica("Prețul s-a schimbat: #{pret_vechi} -> #{pret_nou} lei (#{semn}#{diferenta} lei)")
```

- `.round(2)` avoids ugly float results like `19.999999999`.
- A negative number already has a `-`, so we only add `+` for increases.

### Problem 3: every notification was titled "Pret scazut!" ("Price dropped!")

Even the "started tracking" and daily messages said "price dropped". **Fix:** make the title a parameter with a default value:

```ruby
def notifica(mesaj, titlu = "Pret schimbat")
  ...
  "Title" => titlu,
```

Calling `notifica("text")` uses the default title, and `notifica("text", "Raport zilnic")` uses a custom one.

> HTTP headers should be plain ASCII, so the titles avoid Romanian letters like `ă` and `ț`. The message body can contain them.

### Problem 4: typo in the product URL

The URL ended in `...los-angeles-lakerss` (extra `s`). It still worked because the site finds the product by its ID (`537721`), but a typo like this could break any time. Fixed to `...los-angeles-lakers` and verified that the page loads and the price is still read correctly.

---

## 3. New feature: daily report at 12:17

Besides change notifications, we wanted a report every day at 12:17 with the current price, even when nothing changed (it was 12:00 at first, then 13:45, now 12:17):

```ruby
if Time.now.hour == 12
  notifica("Prețul de azi: #{pret_nou} lei", "Raport zilnic")
end
```

The bot runs every hour at minute 17, so exactly one run per day happens in hour 12 (at 12:17), and that run sends the report. This is simpler than having a separate "daily" mode or a second schedule.

---

## 4. Running it automatically: GitHub Actions + cron-job.org

A script is only useful if something runs it regularly. The work is split in two:

- **GitHub Actions** runs the bot on GitHub's servers (free for public repos, PC can be off).
- **cron-job.org** is the timer: every hour at minute 17 (`17 * * * *`) it tells GitHub "run the bot now".

### Why not GitHub's own schedule?

At first the workflow used GitHub's built-in timer:

```yaml
on:
  schedule:
    - cron: "17 * * * *"   # minute hour day month weekday → "minute 17 of every hour"
```

In practice it **never ran** on the first day. GitHub's `schedule` is "best effort": a new workflow can take hours before its schedule starts, and runs get delayed or skipped when GitHub is busy (especially at `:00`). For a report that must arrive at an exact time, that's not good enough.

A manual start (`workflow_dispatch`) is handled right away, so we let an external timer press that button for us:

```yaml
on:
  workflow_dispatch:   # started every hour by cron-job.org (or manually from the Actions tab)
```

### How cron-job.org starts the workflow

Every hour cron-job.org sends this HTTP request to GitHub's API:

```
POST https://api.github.com/repos/MerceRares/pret-bot/actions/workflows/pret.yml/dispatches
Authorization: Bearer <token>
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28

{"ref":"main"}
```

- `ref: main` = which branch to run.
- The **token** is a limited password created on GitHub (fine-grained personal access token) that only allows *Actions: Read and write* on this one repo. It is stored only in cron-job.org, **never in the code**: the repo is public, and anyone could use a committed token.

### The workflow file, section by section

The file is `.github/workflows/pret.yml`.

```yaml
permissions:
  contents: write
```

This lets the workflow push commits to the repo (needed below).

```yaml
    env:
      TZ: Europe/Bucharest
```

**Important trick:** GitHub's servers use UTC time. Setting `TZ` makes `Time.now` in Ruby return **Romania time**, so `Time.now.hour == 12` really means 12:xx in Romania. It also handles summer/winter time automatically. Without it we would need to change the code twice a year.

```yaml
    steps:
      - uses: actions/checkout@v5          # download the repo code
      - uses: ruby/setup-ruby@v1           # install Ruby
        with:
          ruby-version: "3.3"
          bundler-cache: true              # install gems from Gemfile.lock (and cache them)
      - name: Check price
        run: bundle exec ruby pret_bot.rb
```

```yaml
      - name: Save new price
        run: |
          git config user.name "pret-bot"
          git config user.email "pret-bot@users.noreply.github.com"
          git add pret.json
          git commit -m "Update price" || echo "No change"
          git push
```

**Why commit `pret.json`?** Every GitHub Actions run starts on a **fresh, empty machine**. Files written during a run disappear afterwards. To remember the last price between runs, the workflow commits `pret.json` back to the repo. The next run's `checkout` downloads it again.

- `|| echo "No change"` stops the step from failing if there's nothing to commit.
- A side effect is a small commit every hour. That's fine.

### The checkout v4 → v5 update

The first run succeeded but showed a warning: `actions/checkout@v4` runs on Node.js 20, which is deprecated. Updating to `@v5` (which uses Node.js 24) removed the warning. Warnings aren't errors, but fixing them early avoids surprises later.

---

## 5. Git and GitHub

- The project was turned into a git repo and pushed to **https://github.com/MerceRares/pret-bot** (public).
- Commits, in order:
  1. Initial commit (the original bot)
  2. IDEAS.md: daily report at noon
  3. Notify on any price change, daily noon report, GitHub Actions workflow
  4. Use actions/checkout@v5
  5. Fix product URL
  6. Run at minute 17 + this CHANGES.md
  7. Remove GitHub's schedule, start the workflow from cron-job.org instead
  8. Daily report at 13:45 (cron-job.org runs at minute 45 of every hour)
  9. Error alert when the price can't be read
  10. Daily report moved to 12:17 (cron-job.org runs at minute 17 of every hour)
  11. Track several products from `produse.json`
  12. Per-product CSS selector (other shops: Intersport, Ritmo)
  13. Price history in `istoric.json` + weekly summary every Sunday at 12:17
  14. Show the site (e.g. `ritmo.ro`) in every notification; reports grouped by site
  - plus automatic "Update price" commits from the bot itself

**Watch out:** the bot pushes to GitHub every hour, so your local copy is often behind. Always run `git pull` before you start working, or your `git push` will be rejected.

---

## 6. Files in the project

| File | Purpose |
|---|---|
| `pret_bot.rb` | The bot itself |
| `produse.json` | The list of products to track (name + link) |
| `pret.json` | The last known price of each product (the bot's "memory") |
| `istoric.json` | One price per day for each product (used for the Sunday weekly summary) |
| `.github/workflows/pret.yml` | Runs the bot on GitHub (started every hour by cron-job.org) |
| `Gemfile` / `Gemfile.lock` | Ruby gems used (`httparty`, `nokogiri`) |
| `test_selector.rb` | Helper script used to find the right CSS selector for the price |
| `IDEAS.md` | Ideas for future features |
| `CHANGES.md` | This document |

---

## 7. Known limitations / things to improve

- **The ntfy topic is public.** Anyone who reads the repo can send notifications to the phone. A better approach is to store it as a GitHub secret (see `IDEAS.md`).
- **If the site changes its HTML**, the selector may stop matching and the run will fail (red X in the Actions tab). The bot doesn't send an alert in that case yet.
- **The token expires.** When it does, cron-job.org's requests fail (it shows errors and can email you) and the bot stops running. Create a new token and paste it into cron-job.org.
- **Only one product** is tracked. `IDEAS.md` describes how to track several.

## 8. How to test

- **Locally:** `bundle exec ruby pret_bot.rb`
- **On GitHub:** repo → **Actions** → **pret-bot** → **Run workflow**
- **Test a notification by hand:**
  ```powershell
  Invoke-WebRequest -Method Post -Body "test" https://ntfy.sh/rares-preturi
  ```
- **Test a "price changed" notification:** edit the `"pret"` value in `pret.json` (e.g. to `200.0`), then run the bot.
