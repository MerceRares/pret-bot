require "httparty"
require "nokogiri"
require "json"
require "net/http"

# ===== CONFIGURARE =====
URL         = "https://www.sportvision.ro/tricou/537721-nike-tricou-los-angeles-lakers"   # pune link-ul tău
SELECTOR    = ".current-price .product-price-value"                # selectorul găsit la pasul 4
FISIER_PRET = "pret.json"
NTFY_TOPIC  = ENV.fetch("NTFY_TOPIC", "rares-preturi")

# ===== 1. Descarcă pagina =====
def descarca_pagina(url)
  raspuns = HTTParty.get(
    url,
    headers: {
      "User-Agent"      => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36",
      "Accept-Language" => "ro-RO,ro;q=0.9"
    },
    timeout: 20
  )
  raise "Eroare HTTP #{raspuns.code}" unless raspuns.code == 200
  raspuns.body
end

# ===== 2. Extrage prețul =====
def extrage_pret(html)
  doc = Nokogiri::HTML(html)

  # Varianta 1: tag-ul ascuns cu prețul curat
  meta = doc.at_css('meta[itemprop="price"]')
  return meta["content"].to_f if meta && meta["content"]

  # Varianta 2: elementul vizibil, ex. "1.299,99 Lei"
  element = doc.at_css(SELECTOR)
  raise "Nu am găsit prețul. Verifică selectorul!" if element.nil?

  text = element.text.strip
  puts "Text găsit pe pagină: #{text.inspect}"
  text.gsub(/[^\d,]/, "").tr(",", ".").to_f   # "1.299,99 Lei" -> 1299.99
end

# ===== 3. Citește / salvează prețul =====
def citeste_pret_vechi
  return nil unless File.exist?(FISIER_PRET)
  JSON.parse(File.read(FISIER_PRET))["pret"]
end

def salveaza_pret(pret)
  date = { pret: pret, actualizat: Time.now.strftime("%Y-%m-%d %H:%M") }
  File.write(FISIER_PRET, JSON.pretty_generate(date))
end

# ===== 4. Notificare pe telefon =====
def notifica(mesaj, titlu = "Pret schimbat")
  uri = URI("https://ntfy.sh/#{NTFY_TOPIC}")
  Net::HTTP.post(uri, mesaj, {
    "Title" => titlu,
    "Tags"  => "moneybag",
    "Click" => URL            # atingi notificarea și se deschide produsul
  })
end

# ===== PROGRAMUL PRINCIPAL =====
begin
  pret_nou = extrage_pret(descarca_pagina(URL))
  raise "Prețul citit nu e valid (#{pret_nou})" if pret_nou <= 0
rescue => e
  notifica("Bot-ul nu a găsit prețul. Eroare: #{e.message}", "Bot-ul are o problema")
  exit 1
end

pret_vechi = citeste_pret_vechi

puts "Preț vechi: #{pret_vechi.inspect} | Preț nou: #{pret_nou}"

if pret_vechi.nil?
  notifica("Am început să urmăresc produsul. Preț actual: #{pret_nou} lei")
elsif pret_nou != pret_vechi
  diferenta = (pret_nou - pret_vechi).round(2)
  semn = diferenta > 0 ? "+" : ""
  notifica("Prețul s-a schimbat: #{pret_vechi} -> #{pret_nou} lei (#{semn}#{diferenta} lei)")
else
  puts "Prețul nu s-a schimbat."
end

# Raport zilnic la 12:17 (cron-job.org pornește bot-ul la minutul 17 al fiecărei ore)
if Time.now.hour == 12
  notifica("Prețul de azi: #{pret_nou} lei", "Raport zilnic")
end

salveaza_pret(pret_nou)