# pret-bot – Ideas for notifications

Goal: get a phone notification (ntfy, topic `rares-preturi`)
- **every day at 12:00 AM (midnight)** with the current price, and
- **whenever the price changes** (up or down).

---

## 1. Notify on any price change (not only drops)

Today the bot only notifies when the price goes **down**. Change the check in `pret_bot.rb`:

```ruby
if pret_vechi.nil?
  notifica("Am început să urmăresc produsul. Preț actual: #{pret_nou} lei")
elsif pret_nou != pret_vechi
  diferenta = (pret_nou - pret_vechi).round(2)
  semn = diferenta > 0 ? "+" : ""
  notifica("Prețul s-a schimbat: #{pret_vechi} -> #{pret_nou} lei (#{semn}#{diferenta} lei)")
end
```

Also pass the title as a parameter, so it doesn't always say "Pret scazut!":

```ruby
def notifica(mesaj, titlu = "Pret schimbat")
  ...
  "Title" => titlu,
```

## 2. Daily price report at midnight

Add a "daily report" mode that always sends the current price, even if it didn't change:

```ruby
if ARGV.include?("--zilnic")
  notifica("Prețul de azi: #{pret_nou} lei", "Raport zilnic")
end
```

Run it with:

```
bundle exec ruby pret_bot.rb --zilnic
```

## 3. Running it automatically

The bot only works when something runs it. Choose one option:

### Option A – Windows Task Scheduler (easiest, runs on your PC)

- Task 1: every day at **00:00** → `bundle exec ruby pret_bot.rb --zilnic`
- Task 2: every **1 hour** → `bundle exec ruby pret_bot.rb` (catches price changes)

Downside: the PC must be on.

### Option B – GitHub Actions (free, runs in the cloud, PC can be off)

Create `.github/workflows/pret.yml`:

```yaml
name: pret-bot
on:
  schedule:
    - cron: "0 * * * *"     # every hour – check for price changes
    - cron: "0 21 * * *"    # 21:00 UTC = 00:00 Romania (summer time, UTC+3)
  workflow_dispatch:         # lets you run it manually from GitHub

permissions:
  contents: write

jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
          bundler-cache: true
      - name: Check price
        run: |
          if [ "${{ github.event.schedule }}" = "0 21 * * *" ]; then
            bundle exec ruby pret_bot.rb --zilnic
          else
            bundle exec ruby pret_bot.rb
          fi
      - name: Save new price
        run: |
          git config user.name "pret-bot"
          git config user.email "pret-bot@users.noreply.github.com"
          git add pret.json
          git commit -m "Update price" || echo "No change"
          git push
```

Notes:
- GitHub cron uses **UTC**. Romania is UTC+3 in summer and UTC+2 in winter, so midnight is `0 21 * * *` in summer and `0 22 * * *` in winter.
- GitHub can delay scheduled runs by a few minutes, so "00:00" may arrive at 00:05–00:15.
- `pret.json` gets committed back to the repo so the bot remembers the last price.
- GitHub turns off scheduled workflows in repos with no activity for 60 days. The hourly commits when the price changes help, but you may need to re-enable it sometimes.

## 4. More ideas

- **Watch several products**: put a list of URLs in a `produse.json` file and loop over them.
- **Price history**: save every price with its date in `istoric.json`, and send the lowest price ever in the daily report.
- **Target price**: notify only when the price goes under a value you choose (e.g. `PRET_TINTA = 150`).
- **Error alerts**: if the page can't be downloaded or the selector stops working, send a notification "Bot-ul nu a găsit prețul" so you know it's broken.
- **Private topic**: the repo is public, so anyone can see the topic `rares-preturi` and send you messages. Move the topic to a secret: in GitHub Actions use `NTFY_TOPIC: ${{ secrets.NTFY_TOPIC }}`, and pick a harder-to-guess name.
