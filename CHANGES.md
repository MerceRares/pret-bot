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

## 3. New feature: daily report at 12:00

Besides change notifications, we wanted a report every day at noon with the current price, even when nothing changed:

```ruby
if Time.now.hour == 12
  notifica("Prețul de azi: #{pret_nou} lei", "Raport zilnic")
end
```

The bot runs every hour, so exactly one run per day falls between 12:00 and 12:59, and that run sends the report. This is simpler than having a separate "daily" mode or a second schedule.

---

## 4. Running it automatically: GitHub Actions

A script is only useful if something runs it regularly. We chose **GitHub Actions**: it's free for public repos and runs on GitHub's servers, so the PC can be off.

The file is `.github/workflows/pret.yml`. Here it is section by section:

```yaml
on:
  schedule:
    - cron: "17 * * * *"  # every hour, at minute 17
  workflow_dispatch:       # adds a "Run workflow" button for manual runs
```

`cron` syntax is `minute hour day month weekday`, and `*` means "any". So `17 * * * *` means "minute 17 of every hour".

**Why minute 17 and not 0?** Most workflows in the world are scheduled at `:00`, so GitHub is overloaded then and often delays or even skips runs. GitHub's own docs recommend picking a different minute. In our first test, the `:00` run was skipped, so we moved it to `:17`.

```yaml
permissions:
  contents: write
```

This lets the workflow push commits to the repo (needed below).

```yaml
    env:
      TZ: Europe/Bucharest
```

**Important trick:** GitHub's servers use UTC time. Setting `TZ` makes `Time.now` in Ruby return **Romania time**, so `Time.now.hour == 12` really means noon in Romania. It also handles summer/winter time automatically. Without it we would need to change the code twice a year.

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
- A side effect is a small commit every hour. That's fine, and it also counts as repo activity: GitHub disables scheduled workflows in repos with no activity for 60 days.

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
  - plus automatic "Update price" commits from the bot itself

**Watch out:** the bot pushes to GitHub every hour, so your local copy is often behind. Always run `git pull` before you start working, or your `git push` will be rejected.

---

## 6. Files in the project

| File | Purpose |
|---|---|
| `pret_bot.rb` | The bot itself |
| `pret.json` | The last known price (the bot's "memory") |
| `.github/workflows/pret.yml` | Runs the bot every hour on GitHub |
| `Gemfile` / `Gemfile.lock` | Ruby gems used (`httparty`, `nokogiri`) |
| `test_selector.rb` | Helper script used to find the right CSS selector for the price |
| `IDEAS.md` | Ideas for future features |
| `CHANGES.md` | This document |

---

## 7. Known limitations / things to improve

- **The ntfy topic is public.** Anyone who reads the repo can send notifications to the phone. A better approach is to store it as a GitHub secret (see `IDEAS.md`).
- **If the site changes its HTML**, the selector may stop matching and the run will fail (red X in the Actions tab). The bot doesn't send an alert in that case yet.
- **GitHub can delay scheduled runs**, so the noon report (scheduled for 12:17) may arrive a bit later. In rare cases a delayed run can miss the 12:xx hour and skip the report that day.
- **Only one product** is tracked. `IDEAS.md` describes how to track several.

## 8. How to test

- **Locally:** `bundle exec ruby pret_bot.rb`
- **On GitHub:** repo → **Actions** → **pret-bot** → **Run workflow**
- **Test a notification by hand:**
  ```powershell
  Invoke-WebRequest -Method Post -Body "test" https://ntfy.sh/rares-preturi
  ```
- **Test a "price changed" notification:** edit the `"pret"` value in `pret.json` (e.g. to `200.0`), then run the bot.
